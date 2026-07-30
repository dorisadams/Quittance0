import { stellarService, PaymentRecord } from './stellar.service';
import invoiceService from './invoice.service';
import { SELLER_PUBLIC_KEY } from '../config/stellar';
import { pool } from '../config/database';
import { getErrorMessage } from '../utils/errors';

interface StreamHandle {
  closeHandler: (() => void) | null;
  publicKey: string;
  restartTimeout?: ReturnType<typeof setTimeout>;
}

class PaymentMonitorService {
  /** Per-seller stream registry — one entry per monitored publicKey. */
  private streams = new Map<string, StreamHandle>();
  /** Global expiration-check interval (runs once, not per-key). */
  private expirationInterval: ReturnType<typeof setInterval> | null = null;

  // ── Public API ──────────────────────────────────────────────

  /**
   * Start monitoring payments for `publicKey`. Non-blocking —
   * multiple keys can be monitored simultaneously. Defaults to
   * `SELLER_PUBLIC_KEY` for backward compatibility with `server.ts`.
   */
  start(publicKey: string = SELLER_PUBLIC_KEY): void {
    if (this.streams.has(publicKey)) {
      console.log(`⚠️  Payment monitor already active for ${publicKey}`);
      return;
    }

    console.log(`🚀 Starting payment monitor for: ${publicKey}`);

    const closeHandler = stellarService.streamPayments(
      publicKey,
      (payment) => this.handlePayment(payment),
      (error) => this.handleError(error, publicKey),
    );

    this.streams.set(publicKey, { closeHandler, publicKey });
    this.ensureExpirationCheck();

    console.log(`✅ Payment monitor started for ${publicKey} (total: ${this.streams.size})`);
  }

  /**
   * Stop monitoring `publicKey`. If omitted, stops ALL streams.
   */
  stop(publicKey?: string): void {
    if (publicKey) {
      this.stopOne(publicKey);
    } else {
      console.log(`🛑 Stopping all payment monitors (${this.streams.size} active)...`);
      for (const key of this.streams.keys()) {
        this.stopOne(key);
      }
    }
  }

  /** Whether a specific key is currently being monitored. */
  isMonitoring(publicKey: string): boolean {
    return this.streams.has(publicKey);
  }

  /** Currently monitored public keys. */
  get monitoredKeys(): string[] {
    return Array.from(this.streams.keys());
  }

  /**
   * Manual sync — fetch recent payments for a seller and process them.
   */
  async manualSync(limit: number = 50, publicKey: string = SELLER_PUBLIC_KEY): Promise<void> {
    console.log(`🔄 Starting manual payment sync for: ${publicKey}`);

    try {
      const payments = await stellarService.getRecentPayments(publicKey, limit);

      for (const payment of payments) {
        await this.handlePayment(payment);
      }

      console.log(`✅ Manual sync completed, processed ${payments.length} payments`);
    } catch (error) {
      console.error('❌ Manual sync error:', error);
      throw error;
    }
  }

  // ── Internal — payment processing ───────────────────────────

  private async handlePayment(payment: PaymentRecord): Promise<void> {
    try {
      console.log('🔍 Processing payment:', payment.txHash);

      if (!payment.memo) {
        console.log('⚠️ Payment without memo, skipping:', payment.txHash);
        return;
      }

      const invoice = await invoiceService.getInvoiceByMemo(payment.memo);

      if (!invoice) {
        console.log('⚠️ No invoice found for memo:', payment.memo);
        return;
      }

      if (invoice.status === 'PAID') {
        console.log('⚠️ Invoice already paid:', invoice.id);
        return;
      }

      if (invoice.status === 'EXPIRED') {
        console.log('⚠️ Invoice is expired:', invoice.id);
        return;
      }

      const expectedAmount = invoice.amount.toFixed(7);
      const receivedAmount = parseFloat(payment.amount).toFixed(7);

      if (expectedAmount !== receivedAmount) {
        console.log('⚠️ Amount mismatch:', {
          expected: expectedAmount,
          received: receivedAmount,
          invoiceId: invoice.id,
        });

        await invoiceService.logPaymentEvent(invoice.id, 'PARTIAL_PAYMENT', {
          txHash: payment.txHash,
          expectedAmount,
          receivedAmount,
          payerPublicKey: payment.from,
        });

        return;
      }

      if (payment.assetCode !== invoice.assetCode) {
        console.log('⚠️ Asset mismatch:', {
          expected: invoice.assetCode,
          received: payment.assetCode,
          invoiceId: invoice.id,
        });
        return;
      }

      await this.saveTransaction(payment, invoice.id);
      await invoiceService.markAsPaid(invoice.id, payment.txHash, payment.from);

      console.log('✅ Payment processed successfully:', {
        invoiceId: invoice.id,
        txHash: payment.txHash,
        amount: payment.amount,
      });
    } catch (error: unknown) {
      console.error('❌ Error processing payment:', getErrorMessage(error));
    }
  }

  private async saveTransaction(payment: PaymentRecord, invoiceId: string): Promise<void> {
    const query = `
      INSERT INTO transactions (
        invoice_id, from_address, to_address, amount, asset_code, asset_issuer,
        tx_hash, memo, ledger, processed_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
      ON CONFLICT (tx_hash) DO NOTHING
    `;

    await pool.query(query, [
      invoiceId,
      payment.from,
      payment.to,
      payment.amount,
      payment.assetCode,
      payment.assetIssuer || null,
      payment.txHash,
      payment.memo || null,
      payment.ledger,
    ]);
    console.log('💾 Transaction saved to database');
  }

  // ── Internal — stream lifecycle ─────────────────────────────

  private stopOne(publicKey: string): void {
    const handle = this.streams.get(publicKey);
    if (!handle) {
      console.log(`⚠️  No active monitor for ${publicKey}`);
      return;
    }

    // Cancel any pending error-restart timer so a deliberate
    // stop() call isn't undermined by a stale handleError timeout.
    if (handle.restartTimeout) {
      clearTimeout(handle.restartTimeout);
    }

    if (handle.closeHandler) {
      handle.closeHandler();
    }
    this.streams.delete(publicKey);
    console.log(`🛑 Payment monitor stopped for ${publicKey} (remaining: ${this.streams.size})`);

    if (this.streams.size === 0) {
      this.clearExpirationCheck();
    }
  }

  private handleError(error: Error, publicKey: string): void {
    console.error(`❌ Payment stream error for ${publicKey}:`, error.message ?? error);

    // Remove the dead stream entry so restart creates a fresh one
    this.streams.delete(publicKey);

    // Schedule restart after back-off
    const handle: StreamHandle = { closeHandler: null, publicKey };
    handle.restartTimeout = setTimeout(() => {
      if (!this.streams.has(publicKey)) {
        console.log(`🔄 Restarting payment stream for ${publicKey}...`);
        this.start(publicKey);
      }
    }, 5000);
    this.streams.set(publicKey, handle);
  }

  // ── Internal — expiration check ─────────────────────────────

  private ensureExpirationCheck(): void {
    if (this.expirationInterval) return;

    this.expirationInterval = setInterval(async () => {
      try {
        await invoiceService.markExpiredInvoices();
      } catch (error) {
        console.error('Error checking expired invoices:', error);
      }
    }, 60000);
  }

  private clearExpirationCheck(): void {
    if (this.expirationInterval) {
      clearInterval(this.expirationInterval);
      this.expirationInterval = null;
    }
  }
}

export default new PaymentMonitorService();
