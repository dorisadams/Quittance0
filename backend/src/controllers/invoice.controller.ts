import { Request, Response } from 'express';
import invoiceService from '../services/invoice.service';
import { stellarService } from '../services/stellar.service';
import { createInvoiceSchema } from '../utils/validation';
import { generatePaymentQR, generateStellarPaymentQR } from '../utils/qrcode';
import { getErrorMessage } from '../utils/errors';
import type { Horizon } from '@stellar/stellar-sdk';

class InvoiceController {
  async createInvoice(req: Request, res: Response) {
    try {
      const validatedData = createInvoiceSchema.parse(req.body);
      const invoice = await invoiceService.createInvoice(validatedData);
      const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:3000';
      const paymentUrl = `${frontendUrl}/pay/${invoice.id}`;
      const qrCodeDataUrl = await generatePaymentQR(paymentUrl);
      const stellarQrCode = await generateStellarPaymentQR(
        invoice.sellerPublicKey,
        invoice.amount.toString(),
        invoice.assetCode,
        invoice.memo
      );

      res.status(201).json({
        success: true,
        data: {
          invoice,
          paymentUrl,
          qrCode: qrCodeDataUrl,
          stellarQrCode,
        },
      });
    } catch (error: unknown) {
      res.status(400).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to create invoice',
      });
    }
  }

  async getInvoice(req: Request, res: Response) {
    try {
      const { id } = req.params;
      const invoice = await invoiceService.getInvoiceById(id);

      if (!invoice) {
        return res.status(404).json({
          success: false,
          error: 'Invoice not found',
        });
      }

      res.json({
        success: true,
        data: invoice,
      });
    } catch (error: unknown) {
      res.status(500).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to get invoice',
      });
    }
  }

  async getInvoices(req: Request, res: Response) {
    try {
      const { status, limit = 50, offset = 0, sellerPublicKey } = req.query;

      if (!sellerPublicKey || typeof sellerPublicKey !== 'string') {
        return res.status(400).json({
          success: false,
          error: 'sellerPublicKey query parameter is required',
        });
      }

      const invoices = await invoiceService.getInvoicesBySeller(
        sellerPublicKey,
        status as string | undefined,
        parseInt(limit as string),
        parseInt(offset as string)
      );

      res.json({
        success: true,
        data: invoices,
        pagination: {
          limit: parseInt(limit as string),
          offset: parseInt(offset as string),
          total: invoices.length,
        },
      });
    } catch (error: unknown) {
      res.status(500).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to get invoices',
      });
    }
  }

  async cancelInvoice(req: Request, res: Response) {
    try {
      const { id } = req.params;
      const invoice = await invoiceService.cancelInvoice(id);

      res.json({
        success: true,
        data: invoice,
      });
    } catch (error: unknown) {
      res.status(400).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to cancel invoice',
      });
    }
  }

  async verifyPayment(req: Request, res: Response) {
    try {
      const { id } = req.params;
      const { txHash, payerName, payerEmail } = req.body;

      if (!txHash) {
        return res.status(400).json({
          success: false,
          error: 'Transaction hash is required',
        });
      }

      const invoice = await invoiceService.getInvoiceById(id);

      if (!invoice) {
        return res.status(404).json({
          success: false,
          error: 'Invoice not found',
        });
      }

      const txDetails = await stellarService.getTransaction(txHash);
      const transaction = txDetails.transaction;
      const paymentOp = txDetails.operations.find(
        (op) => op.type === 'payment'
      ) as Horizon.ServerApi.PaymentOperationRecord | undefined;

      if (!paymentOp) {
        return res.status(400).json({
          success: false,
          error: 'No payment operation found',
        });
      }

      if (transaction.memo !== invoice.memo) {
        return res.status(400).json({
          success: false,
          error: 'Memo mismatch',
        });
      }

      if (parseFloat(paymentOp.amount).toFixed(7) !== invoice.amount.toFixed(7)) {
        return res.status(400).json({
          success: false,
          error: 'Amount mismatch',
        });
      }

      const updatedInvoice = await invoiceService.markAsPaid(
        invoice.id,
        txHash,
        paymentOp.from,
        { payerName, payerEmail }
      );

      res.json({
        success: true,
        data: updatedInvoice,
      });
    } catch (error: unknown) {
      res.status(500).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to verify payment',
      });
    }
  }

  async getStats(req: Request, res: Response) {
    try {
      const { sellerPublicKey } = req.query;

      if (!sellerPublicKey || typeof sellerPublicKey !== 'string') {
        return res.status(400).json({
          success: false,
          error: 'sellerPublicKey query parameter is required',
        });
      }

      const stats = await invoiceService.getInvoiceStats(sellerPublicKey);

      res.json({
        success: true,
        data: stats,
      });
    } catch (error: unknown) {
      res.status(500).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to get stats',
      });
    }
  }

  async getPaymentInfo(req: Request, res: Response) {
    try {
      const { id } = req.params;
      const invoice = await invoiceService.getInvoiceById(id);

      if (!invoice) {
        return res.status(404).json({
          success: false,
          error: 'Invoice not found',
        });
      }

      const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:3000';
      const paymentUrl = `${frontendUrl}/pay/${invoice.id}`;

      const qrCodeDataUrl = await generatePaymentQR(paymentUrl);
      const stellarQrCode = await generateStellarPaymentQR(
        invoice.sellerPublicKey,
        invoice.amount.toString(),
        invoice.assetCode,
        invoice.memo
      );

      res.json({
        success: true,
        data: {
          paymentUrl,
          qrCode: qrCodeDataUrl,
          stellarQrCode,
          invoice,
        },
      });
    } catch (error: unknown) {
      res.status(500).json({
        success: false,
        error: getErrorMessage(error) || 'Failed to get payment info',
      });
    }
  }
}

export default new InvoiceController();

