import { Resend } from 'resend';
import { getErrorMessage } from '../utils/errors';
import type { Invoice } from './invoice.service';

const FROM_EMAIL = process.env.FROM_EMAIL || 'quittance@resend.dev';

let _resend: Resend | null = null;

function getResend(): Resend {
  if (!_resend) {
    const apiKey = process.env.RESEND_API_KEY;
    if (!apiKey) {
      throw new Error('RESEND_API_KEY environment variable is not set');
    }
    _resend = new Resend(apiKey);
  }
  return _resend;
}

/**
 * Send the invoice payment link to the client.
 * Uses the Resend transactional email API.
 */
export async function sendInvoiceLink(
  invoice: Invoice,
  paymentUrl: string
): Promise<{ id: string }> {
  if (!invoice.customerEmail) {
    throw new Error('Client email is required to send invoice');
  }

  try {
    const resend = getResend();
    const subject = `Invoice #${invoice.id.substring(0, 8).toUpperCase()} — ${invoice.amount} ${invoice.assetCode}`;

    const { data, error } = await resend.emails.send({
      from: `Quittance <${FROM_EMAIL}>`,
      to: [invoice.customerEmail],
      subject,
      html: buildInvoiceEmailHtml(invoice, paymentUrl),
    });

    if (error) {
      throw new Error(`Resend error: ${error.message}`);
    }

    console.log(`📧 Invoice link sent to ${invoice.customerEmail} (resend: ${data?.id})`);
    return { id: data?.id ?? 'unknown' };
  } catch (error: unknown) {
    console.error('Failed to send invoice link:', error);
    throw new Error(`Failed to send invoice email: ${getErrorMessage(error)}`);
  }
}

/**
 * Send payment proof to the client after successful payment.
 */
export async function sendPaymentProof(
  invoice: Invoice
): Promise<{ id: string }> {
  if (!invoice.customerEmail) {
    throw new Error('Client email is required to send proof');
  }

  if (invoice.status !== 'PAID') {
    throw new Error('Invoice must be paid before sending proof');
  }

  try {
    const resend = getResend();
    const subject = `Payment Confirmed — Invoice #${invoice.id.substring(0, 8).toUpperCase()}`;

    const { data, error } = await resend.emails.send({
      from: `Quittance <${FROM_EMAIL}>`,
      to: [invoice.customerEmail],
      subject,
      html: buildProofEmailHtml(invoice),
    });

    if (error) {
      throw new Error(`Resend error: ${error.message}`);
    }

    console.log(`📧 Payment proof sent to ${invoice.customerEmail} (resend: ${data?.id})`);
    return { id: data?.id ?? 'unknown' };
  } catch (error: unknown) {
    console.error('Failed to send payment proof:', error);
    throw new Error(`Failed to send proof email: ${getErrorMessage(error)}`);
  }
}

function buildInvoiceEmailHtml(invoice: Invoice, paymentUrl: string): string {
  const name = invoice.customerName || 'there';
  return `
<!DOCTYPE html>
<html>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #1f2937;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #4f46e5; margin: 0;">💫 Quittance</h1>
  </div>

  <p style="font-size: 16px;">Hi ${name},</p>

  <p>You have a new invoice from <strong>${invoice.sellerPublicKey.substring(0, 8)}…</strong>.</p>

  <div style="background: #f9fafb; border-radius: 8px; padding: 20px; margin: 20px 0;">
    <table style="width: 100%; border-collapse: collapse;">
      <tr><td style="padding: 8px 0; color: #6b7280;">Description</td><td style="font-weight: 500;">${invoice.description || '—'}</td></tr>
      <tr><td style="padding: 8px 0; color: #6b7280;">Amount</td><td style="font-weight: 700; font-size: 18px; color: #4f46e5;">${invoice.amount} ${invoice.assetCode}</td></tr>
    </table>
  </div>

  <div style="text-align: center; margin: 30px 0;">
    <a href="${paymentUrl}" style="background: #4f46e5; color: white; padding: 14px 32px; border-radius: 8px; text-decoration: none; font-weight: 600; display: inline-block;">
      Pay Invoice
    </a>
  </div>

  <p style="font-size: 14px; color: #6b7280;">Or copy this link: <br><code>${paymentUrl}</code></p>

  <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 30px 0;">

  <p style="font-size: 12px; color: #9ca3af; text-align: center;">
    Payment settled on Stellar • Powered by Quittance
  </p>
</body>
</html>`;
}

function buildProofEmailHtml(invoice: Invoice): string {
  const name = invoice.customerName || 'there';
  return `
<!DOCTYPE html>
<html>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #1f2937;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #059669; margin: 0;">✅ Payment Confirmed</h1>
  </div>

  <p style="font-size: 16px;">Hi ${name},</p>

  <p>Payment for invoice <strong>#${invoice.id.substring(0, 8).toUpperCase()}</strong> has been confirmed on the Stellar blockchain.</p>

  <div style="background: #f0fdf4; border: 1px solid #86efac; border-radius: 8px; padding: 20px; margin: 20px 0;">
    <table style="width: 100%; border-collapse: collapse;">
      <tr><td style="padding: 8px 0; color: #6b7280;">Amount Paid</td><td style="font-weight: 700; font-size: 18px; color: #059669;">${invoice.amount} ${invoice.assetCode}</td></tr>
      <tr><td style="padding: 8px 0; color: #6b7280;">Description</td><td style="font-weight: 500;">${invoice.description || '—'}</td></tr>
      <tr><td style="padding: 8px 0; color: #6b7280;">Transaction</td><td style="font-family: monospace; font-size: 12px;">${invoice.paymentTxHash?.substring(0, 16)}…</td></tr>
    </table>
  </div>

  <p style="font-size: 14px; color: #6b7280;">This receipt is cryptographically verifiable on Stellar. Your freelancer can provide the full transaction hash for on-chain verification.</p>

  <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 30px 0;">

  <p style="font-size: 12px; color: #9ca3af; text-align: center;">
    Payment settled on Stellar • Powered by Quittance
  </p>
</body>
</html>`;
}
