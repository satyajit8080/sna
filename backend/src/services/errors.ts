/**
 * Errors that originate from a service we call rather than from our own code.
 *
 * Lives in its own module so both the AI and food clients can throw it without
 * one provider file importing another.
 */
export class UpstreamError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryable: boolean
  ) {
    super(message);
    this.name = "UpstreamError";
  }
}
