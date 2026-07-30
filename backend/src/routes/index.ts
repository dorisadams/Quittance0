import { Router } from 'express';
import invoiceController from '../controllers/invoice.controller';
import stellarController from '../controllers/stellar.controller';
import paymentMonitorService from '../services/payment-monitor.service';
import invoiceService from '../services/invoice.service';
import { sendInvoiceLink, sendPaymentProof } from '../services/email.service';
import { getErrorMessage } from '../utils/errors';

const router = Router();

// Health check
router.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    service: 'Quittance API',
    mode: 'PostgreSQL — Dynamic Seller',
  });
});

// Invoice routes
router.post('/invoices', invoiceController.createInvoice.bind(invoiceController));
router.get('/invoices', invoiceController.getInvoices.bind(invoiceController));
router.get('/invoices/stats', invoiceController.getStats.bind(invoiceController));
router.get('/invoices/:id', invoiceController.getInvoice.bind(invoiceController));
router.get('/invoices/:id/payment-info', invoiceController.getPaymentInfo.bind(invoiceController));
router.post('/invoices/:id/cancel', invoiceController.cancelInvoice.bind(invoiceController));
router.post('/invoices/:id/verify', invoiceController.verifyPayment.bind(invoiceController));

// Stellar routes
router.get('/stellar/account', stellarController.getAccountInfo.bind(stellarController));
router.get('/stellar/payments', stellarController.getPayments.bind(stellarController));
router.get('/stellar/transaction/:hash', stellarController.getTransaction.bind(stellarController));
router.post('/stellar/verify-payment', stellarController.verifyPayment.bind(stellarController));

// Email routes
router.post('/invoices/:id/send', async (req, res) => {
  try {
    const { id } = req.params;
    const invoice = await invoiceService.getInvoiceById(id);

    if (!invoice) {
      return res.status(404).json({ success: false, error: 'Invoice not found' });
    }

    const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:3000';
    const paymentUrl = `${frontendUrl}/pay/${invoice.id}`;

    const result = await sendInvoiceLink(invoice, paymentUrl);

    res.json({ success: true, data: result });
  } catch (error: unknown) {
    const message = getErrorMessage(error);
    const status = message.includes('required') || message.includes('must be paid') ? 400 : 500;
    res.status(status).json({ success: false, error: message || 'Failed to send invoice' });
  }
});

router.post('/invoices/:id/email-proof', async (req, res) => {
  try {
    const { id } = req.params;
    const invoice = await invoiceService.getInvoiceById(id);

    if (!invoice) {
      return res.status(404).json({ success: false, error: 'Invoice not found' });
    }

    if (invoice.status !== 'PAID') {
      return res.status(400).json({ success: false, error: 'Invoice is not paid yet' });
    }

    const result = await sendPaymentProof(invoice);

    res.json({ success: true, data: result });
  } catch (error: unknown) {
    const message = getErrorMessage(error);
    const status = message.includes('required') || message.includes('must be paid') ? 400 : 500;
    res.status(status).json({ success: false, error: message || 'Failed to send proof' });
  }
});

// Payment monitoring routes
router.post('/payment/sync', async (req, res) => {
  try {
    const limit = req.body.limit || 50;
    await paymentMonitorService.manualSync(limit);
    res.json({
      success: true,
      message: `Payment sync completed`,
      limit
    });
  } catch (error: unknown) {
    res.status(500).json({
      success: false,
      error: getErrorMessage(error) || 'Sync failed'
    });
  }
});

export default router;

