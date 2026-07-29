/**
 * Shared backend invoice types — imported by both the in-memory storage
 * (`memory-storage.ts`) and the SQL-backed service (`invoice.service.ts`)
 * so neither backend depends on the other for domain types.
 */

/**
 * Per-asset stats returned by GET /invoices/stats. Mirrors the frontend
 * `InvoiceStats` (frontend/lib/utils.ts). Fields are `string | number`
 * because the SQL path (invoice.service.ts) returns BigInt-strigified
 * columns from node-postgres while the in-memory path returns raw
 * JavaScript numbers.
 */
export interface InvoiceStats {
  total_invoices: string | number;
  paid_invoices: string | number;
  pending_invoices: string | number;
  expired_invoices: string | number;
  total_revenue: string | number;
  asset_code: string;
}
