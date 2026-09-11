export type BudgetDecision =
  | { allowed: true; remainingDaily: number; remainingPerSecond: number }
  | { allowed: false; reason: "quota_unconfigured" | "daily_exhausted" | "second_exhausted"; retryAfterMs: number | null };

export type RequestBudgetOptions = {
  dailyLimit: number | null;
  perSecondLimit: number | null;
  dayStartedAtUtcMs: number;
};

export class RequestBudget {
  readonly #dailyLimit: number | null;
  readonly #perSecondLimit: number | null;
  readonly #dayStartedAtUtcMs: number;
  #dailyUsed = 0;
  #secondBucketStartedAtMs: number | null = null;
  #secondUsed = 0;

  constructor(options: RequestBudgetOptions) {
    this.#dailyLimit = options.dailyLimit;
    this.#perSecondLimit = options.perSecondLimit;
    this.#dayStartedAtUtcMs = options.dayStartedAtUtcMs;
  }

  get dailyUsed(): number {
    return this.#dailyUsed;
  }

  reserve(nowUtcMs: number): BudgetDecision {
    if (this.#dailyLimit === null || this.#perSecondLimit === null) {
      return { allowed: false, reason: "quota_unconfigured", retryAfterMs: null };
    }
    if (nowUtcMs - this.#dayStartedAtUtcMs >= 86_400_000) {
      return { allowed: false, reason: "daily_exhausted", retryAfterMs: null };
    }
    if (this.#dailyUsed >= this.#dailyLimit) {
      return { allowed: false, reason: "daily_exhausted", retryAfterMs: null };
    }

    const bucketStart = Math.floor(nowUtcMs / 1000) * 1000;
    if (this.#secondBucketStartedAtMs !== bucketStart) {
      this.#secondBucketStartedAtMs = bucketStart;
      this.#secondUsed = 0;
    }
    if (this.#secondUsed >= this.#perSecondLimit) {
      return { allowed: false, reason: "second_exhausted", retryAfterMs: bucketStart + 1000 - nowUtcMs };
    }

    this.#dailyUsed += 1;
    this.#secondUsed += 1;
    return {
      allowed: true,
      remainingDaily: this.#dailyLimit - this.#dailyUsed,
      remainingPerSecond: this.#perSecondLimit - this.#secondUsed
    };
  }
}

export function retryDelayMs(attempt: number, providerRetryAfterMs: number | null): number {
  if (providerRetryAfterMs !== null) {
    return Math.min(providerRetryAfterMs, 60_000);
  }
  const boundedAttempt = Math.max(0, Math.min(attempt, 6));
  return Math.min(1000 * 2 ** boundedAttempt, 60_000);
}
