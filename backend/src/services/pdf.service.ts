import PDFDocument from 'pdfkit';
import { format } from 'date-fns';
import type { Invoice } from './invoice.service';

/**
 * Generate a payment proof PDF for a paid invoice.
 * Returns the PDF as a Buffer ready for HTTP download.
 */
export async function generatePaymentProof(invoice: Invoice): Promise<Buffer> {
  if (invoice.status !== 'PAID') {
    throw new Error('Invoice must be paid to generate proof');
  }

  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const doc = new PDFDocument({
      size: 'A4',
      margins: { top: 50, bottom: 50, left: 50, right: 50 },
      info: {
        Title: `Payment Proof — Invoice #${invoice.id.substring(0, 8).toUpperCase()}`,
        Author: 'Quittance',
        Subject: 'Stellar Payment Proof',
      },
    });

    doc.on('data', (chunk: Buffer) => chunks.push(chunk));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    // ── Header ──
    doc
      .fontSize(24)
      .font('Helvetica-Bold')
      .fillColor('#4f46e5')
      .text('💫 Quittance', { align: 'center' });

    doc
      .fontSize(14)
      .font('Helvetica')
      .fillColor('#374151')
      .text('Payment Proof', { align: 'center' });

    doc.moveDown(0.5);

    // Green checkmark
    doc
      .fontSize(12)
      .font('Helvetica-Bold')
      .fillColor('#059669')
      .text('✓ PAYMENT CONFIRMED', { align: 'center' });

    doc.moveDown(0.5);

    // ── Divider ──
    drawDivider(doc);

    // ── Amount ──
    doc.moveDown(0.5);
    doc
      .fontSize(11)
      .font('Helvetica')
      .fillColor('#6b7280')
      .text('Amount Paid', { align: 'center' });

    doc
      .fontSize(28)
      .font('Helvetica-Bold')
      .fillColor('#059669')
      .text(`${invoice.amount} ${invoice.assetCode}`, { align: 'center' });

    doc.moveDown(0.5);
    drawDivider(doc);

    // ── Invoice Details ──
    doc.moveDown(0.5);
    doc.fontSize(12).font('Helvetica-Bold').fillColor('#1f2937').text('Invoice Details');

    const detailsLeft = 80;
    doc.moveDown(0.3);
    detailRow(doc, 'Invoice ID', invoice.id);
    detailRow(doc, 'Memo', invoice.memo);
    if (invoice.description) {
      detailRow(doc, 'Description', invoice.description);
    }
    if (invoice.customerEmail) {
      detailRow(doc, 'Client Email', invoice.customerEmail);
    }
    if (invoice.customerName) {
      detailRow(doc, 'Client Name', invoice.customerName);
    }
    detailRow(doc, 'Paid At', format(invoice.paidAt!, 'PPpp'));
    detailRow(doc, 'Asset', invoice.assetCode);

    doc.moveDown(0.5);
    drawDivider(doc);

    // ── Transaction Details ──
    doc.moveDown(0.5);
    doc.fontSize(12).font('Helvetica-Bold').fillColor('#1f2937').text('Transaction Details');
    doc.moveDown(0.3);

    detailRow(doc, 'Transaction Hash', invoice.paymentTxHash, true);
    detailRow(doc, 'Payer Address', invoice.payerPublicKey, true);
    detailRow(doc, 'Seller Address', invoice.sellerPublicKey, true);

    doc.moveDown(0.5);

    // ── Info box ──
    doc
      .rect(50, doc.y, doc.page.width - 100, 36)
      .fillAndStroke('#f0fdf4', '#86efac');

    doc
      .fontSize(9)
      .font('Helvetica')
      .fillColor('#065f46')
      .text('This payment has been verified and recorded on the Stellar blockchain.', 60, doc.y - 28, {
        width: doc.page.width - 120,
        align: 'center',
      });

    doc.moveDown(1.5);

    // ── Footer ──
    doc
      .fontSize(8)
      .font('Helvetica')
      .fillColor('#9ca3af')
      .text('Powered by Quittance — Stellar Payment Platform', { align: 'center' });

    doc
      .fontSize(7)
      .fillColor('#d1d5db')
      .text(`Generated on ${format(new Date(), 'PPpp')}`, { align: 'center' });

    doc.end();
  });
}

function drawDivider(doc: typeof PDFDocument) {
  doc
    .moveTo(50, doc.y)
    .lineTo(doc.page.width - 50, doc.y)
    .strokeColor('#e5e7eb')
    .lineWidth(1)
    .stroke();
}

function detailRow(
  doc: typeof PDFDocument,
  label: string,
  value: string,
  small: boolean = false,
) {
  doc
    .fontSize(9)
    .font('Helvetica')
    .fillColor('#6b7280')
    .text(label, 50, doc.y, { width: 130, continued: true });

  doc
    .fontSize(small ? 7 : 9)
    .font(small ? 'Courier' : 'Helvetica')
    .fillColor('#1f2937')
    .text(value, 190);

  doc.moveDown(0.2);
}
