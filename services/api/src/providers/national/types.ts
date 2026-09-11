import type { RuntimeConfig } from "../../config.js";

export const NATIONAL_PROVIDER = "national";
export const NATIONAL_SIGNAL_ENDPOINT = "https://apis.data.go.kr/B551982/rti/tl_drct_info";

export type NationalDirectionCode = "nt" | "et" | "st" | "wt" | "ne" | "se" | "sw" | "nw";

export type NormalizedSignalState = "green" | "yellow" | "red" | "flashing" | "unknown";

export type NationalObservation = {
  schemaVersion: "sa-contract-1";
  kind: "SignalObservation";
  provider: typeof NATIONAL_PROVIDER;
  intersectionKey: string;
  approachKey: string;
  movement: "straight";
  signalState: NormalizedSignalState;
  catalogVersion: string;
  sourceRevision: string;
  sourceIntersectionId: string;
  sourceEventId: string | null;
  sourceObservedAtUtcMs: number | null;
  sourceTimeKind: "unknown" | "generated" | "transmitted";
  serverReceivedAtUtcMs: number;
  serverSentAtUtcMs: number;
  remainingAtSourceMs: number | null;
  expiresAtUtcMs: number | null;
  timingQuality: "unverified" | "verified";
  unitEvidence: {
    sourceField: string;
    sourceUnit: "unknown" | "ms" | "centisecond" | "second";
    conversion: string;
    evidence: string;
  };
  rawStateCode: string | null;
};

export type NationalDiagnostic = {
  approachKey: string;
  sourceDirectionCode: NationalDirectionCode;
  rawRemainingValue: string | null;
  rawTotDt: string | null;
  disabledReason: "UNVERIFIED_UNIT" | "UNKNOWN_SIGNAL" | "EMPTY_DIRECTION";
};

export type NationalParseStatus = "ok" | "empty" | "auth_error" | "rate_limited" | "provider_error" | "malformed";

export type NationalParseResult = {
  status: NationalParseStatus;
  observations: NationalObservation[];
  diagnostics?: NationalDiagnostic[];
  errorCode?: string;
  safeMessage?: string;
};

export type NationalRequest = {
  stdgCd: string | null;
  pageNo: number;
  numOfRows: number;
};

export type NationalQuery = NationalRequest & {
  serviceKey: string;
  type: "json";
};

export function nationalServiceKey(config: RuntimeConfig): string | null {
  return config.providerKeys.national ? (process.env.NATIONAL_SERVICE_KEY?.trim() || null) : null;
}
