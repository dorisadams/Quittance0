/**
 * Extract a human-readable message from an unknown error.
 * Used to replace `catch (error: any)` blocks with typed `catch (error: unknown)`.
 */
export function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
