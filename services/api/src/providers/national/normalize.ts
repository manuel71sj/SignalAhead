import {
  NATIONAL_PROVIDER,
  type NationalDiagnostic,
  type NationalDirectionCode,
  type NationalObservation,
  type NationalParseResult,
  type NormalizedSignalState
} from "./types.js";

const DIRECTION_FIELDS: Record<NationalDirectionCode, { remaining: string; state: string }> = {
  nt: { remaining: "ntStsgRmndCs", state: "ntStsgSttsNm" },
  et: { remaining: "etStsgRmndCs", state: "etStsgSttsNm" },
  st: { remaining: "stStsgRmndCs", state: "stStsgSttsNm" },
  wt: { remaining: "wtStsgRmndCs", state: "wtStsgSttsNm" },
  ne: { remaining: "neStsgRmndCs", state: "neStsgSttsNm" },
  se: { remaining: "seStsgRmndCs", state: "seStsgSttsNm" },
  sw: { remaining: "swStsgRmndCs", state: "swStsgSttsNm" },
  nw: { remaining: "nwStsgRmndCs", state: "nwStsgSttsNm" }
};

const CODE_TO_STATE: Record<string, NormalizedSignalState> = {
  "protected-Movement-Allowed": "green",
  "permissive-Movement-Allowed": "green",
  "stop-And-Remain": "red",
  "protected-clearance": "yellow",
  "permissive-clearance": "yellow",
  "caution-Conflicting-Traffic": "flashing"
};

function safeString(value: unknown): string | null {
  if (typeof value !== "string" && typeof value !== "number") {
    return null;
  }
  const text = String(value).trim();
  return text.length > 0 ? text : null;
}

function objectField(value: unknown, key: string): unknown {
  if (typeof value !== "object" || value === null || !(key in value)) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  return record[key];
}

function itemArray(items: unknown): Record<string, unknown>[] {
  const item = objectField(items, "item");
  if (Array.isArray(item)) {
    return item.filter((entry): entry is Record<string, unknown> => typeof entry === "object" && entry !== null);
  }
  if (typeof item === "object" && item !== null) {
    return [item as Record<string, unknown>];
  }
  return [];
}

function resultCode(payload: Record<string, unknown>): string | null {
  return safeString(objectField(payload.header, "resultCode"));
}

function safeProviderMessage(payload: Record<string, unknown>): string | undefined {
  const raw = safeString(objectField(payload.header, "resultMsg"));
  if (raw === null) {
    return undefined;
  }
  return raw.replace(/([?&](?:serviceKey|ServiceKey)=)[^&\s]+/gu, "$1<redacted>");
}

function providerStatus(
  status: NationalParseResult["status"],
  code: string | null,
  message: string | undefined
): NationalParseResult {
  const result: NationalParseResult = { status, observations: [] };
  if (code !== null) {
    result.errorCode = code;
  }
  if (message !== undefined) {
    result.safeMessage = message;
  }
  return result;
}

function bodyItems(payload: Record<string, unknown>): Record<string, unknown>[] {
  return itemArray(objectField(payload.body, "items"));
}

function normalizeState(rawState: string | null): NormalizedSignalState {
  if (rawState === null) {
    return "unknown";
  }
  return CODE_TO_STATE[rawState] ?? "unknown";
}


function disabledReason(state: NormalizedSignalState, rawRemaining: string | null): NationalDiagnostic["disabledReason"] {
  if (state === "unknown") {
    return rawRemaining === null ? "EMPTY_DIRECTION" : "UNKNOWN_SIGNAL";
  }
  return "UNVERIFIED_UNIT";
}

function normalizeItem(item: Record<string, unknown>, receivedAtUtcMs: number, sentAtUtcMs: number): Array<{ observation: NationalObservation; diagnostic: NationalDiagnostic }> {
  const stdgCd = safeString(item.stdgCd);
  const crsrdId = safeString(item.crsrdId);
  if (stdgCd === null || crsrdId === null) return [];
  const sourceIntersectionId = `${stdgCd}:${crsrdId}`;
  const intersectionKey = `${NATIONAL_PROVIDER}:${sourceIntersectionId}`;
  return (Object.entries(DIRECTION_FIELDS) as Array<[NationalDirectionCode, { remaining: string; state: string }]>).map(([direction, fields]) => {
    const rawState = safeString(item[fields.state]);
    const rawRemaining = safeString(item[fields.remaining]);
    const signalState = normalizeState(rawState);
    const approachKey = `${intersectionKey}:straight:${direction}`;
    return {
      observation: {
        schemaVersion: "sa-contract-1",
        kind: "SignalObservation",
        provider: NATIONAL_PROVIDER,
        intersectionKey,
        approachKey,
        movement: "straight",
        signalState,
        catalogVersion: "unverified-national-live",
        sourceRevision: "unknown",
        sourceIntersectionId,
        sourceEventId: null,
        sourceObservedAtUtcMs: null,
        sourceTimeKind: "unknown",
        serverReceivedAtUtcMs: receivedAtUtcMs,
        serverSentAtUtcMs: sentAtUtcMs,
        remainingAtSourceMs: null,
        expiresAtUtcMs: null,
        timingQuality: "unverified",
        unitEvidence: {
          sourceField: fields.remaining,
          sourceUnit: "unknown",
          conversion: "not converted; source remaining-time unit is unverified",
          evidence: "docs/validation/providers/sa-01.json"
        },
        rawStateCode: rawState
      },
      diagnostic: {
        approachKey,
        sourceDirectionCode: direction,
        rawRemainingValue: rawRemaining,
        rawTotDt: safeString(item.totDt),
        disabledReason: disabledReason(signalState, rawRemaining)
      }
    };
  });
}

export function normalizeNationalTlDrctPayload(
  payload: unknown,
  receivedAtUtcMs: number,
  sentAtUtcMs = receivedAtUtcMs
): NationalParseResult {
  if (typeof payload === "string") {
    return { status: "malformed", observations: [], safeMessage: "Non-JSON provider payload is unsupported" };
  }
  if (typeof payload !== "object" || payload === null) {
    return { status: "malformed", observations: [], safeMessage: "Provider payload is not an object" };
  }

  const envelope = payload as Record<string, unknown>;
  const code = resultCode(envelope);
  if (code === "K3" || code === "K03") {
    return providerStatus("empty", code, safeProviderMessage(envelope));
  }
  if (code === "K20" || code === "K30") {
    return providerStatus("auth_error", code, safeProviderMessage(envelope));
  }
  if (code !== "K0") {
    return providerStatus("provider_error", code, safeProviderMessage(envelope));
  }

  const normalized = bodyItems(envelope).flatMap((item) => normalizeItem(item, receivedAtUtcMs, sentAtUtcMs));
  return {
    status: "ok",
    observations: normalized.map((item) => item.observation),
    diagnostics: normalized.map((item) => item.diagnostic)
  };
}
