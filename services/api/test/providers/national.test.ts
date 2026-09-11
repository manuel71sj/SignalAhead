import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";
import { normalizeNationalTlDrctPayload } from "../../src/providers/national/normalize.js";

function fixture(path: string): unknown {
  return JSON.parse(readFileSync(resolve(process.cwd(), "../..", path), "utf8"));
}

describe("national signal normalization", () => {
  test("normalizes recorded straight signal without approving prediction timing", () => {
    const recorded = fixture("fixtures/providers/national/recorded-straight-signal.json") as { payload: unknown };
    const result = normalizeNationalTlDrctPayload(recorded.payload, 1_789_034_339_610);

    expect(result.status).toBe("ok");
    expect(result.observations).toHaveLength(8);
    const northThrough = result.observations.find((observation) => observation.sourceDirectionCode === "nt");

    expect(northThrough).toMatchObject({
      provider: "national",
      intersectionKey: "national:1100000000:1850",
      approachKey: "national:1100000000:1850:straight:nt",
      sourceIntersectionId: "1100000000:1850",
      signalState: "green",
      remainingAtSourceMs: 21,
      sourceObservedAtUtcMs: null,
      sourceTimeKind: "unknown",
      timingQuality: "unverified",
      disabledForPrediction: true,
      disabledReason: "UNVERIFIED_UNIT"
    });
    expect(northThrough?.unitEvidence).toMatchObject({ sourceUnit: "unknown" });
  });

  test("treats K3 and K03 as empty rather than fatal provider errors", () => {
    const recorded = fixture("fixtures/providers/national/recorded-empty-k3.json") as { payload: unknown };
    const realEmpty = normalizeNationalTlDrctPayload(recorded.payload, 1);
    const documentedEmpty = normalizeNationalTlDrctPayload({ header: { resultCode: "K03", resultMsg: "NODATA_ERROR" } }, 1);

    expect(realEmpty).toMatchObject({ status: "empty", observations: [], errorCode: "K3" });
    expect(documentedEmpty).toMatchObject({ status: "empty", observations: [], errorCode: "K03" });
  });

  test("redacts credential query values from provider error messages", () => {
    const result = normalizeNationalTlDrctPayload(
      { header: { resultCode: "K20", resultMsg: "bad https://example.test/?serviceKey=<fixture-token>&x=1" } },
      1
    );

    expect(result.status).toBe("auth_error");
    expect(result.safeMessage).toBe("bad https://example.test/?serviceKey=<redacted>&x=1");
  });
});
