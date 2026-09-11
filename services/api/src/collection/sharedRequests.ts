import type { NationalRequest } from "../providers/national/types.js";

export type SignalSubscription = {
  subscriptionId: string;
  provider: "national";
  stdgCd: string | null;
};

export function nationalRequestPlan(subscriptions: SignalSubscription[], pageSize: number): NationalRequest[] {
  const stdgCodes = new Set<string | null>();
  for (const subscription of subscriptions) {
    stdgCodes.add(subscription.stdgCd);
  }

  return [...stdgCodes]
    .sort((left, right) => String(left).localeCompare(String(right)))
    .map((stdgCd) => ({ stdgCd, pageNo: 1, numOfRows: pageSize }));
}
