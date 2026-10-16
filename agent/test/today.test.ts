import { describe, it, expect } from "vitest";
import { localToday, timeZoneLabel } from "../src/prompt.js";

describe("localToday", () => {
  it("uses the local calendar date, not UTC", () => {
    process.env.TZ = "America/Mexico_City";
    // 23:30 local del 13 de octubre = 05:30 UTC del 14.
    expect(localToday(new Date(2026, 9, 13, 23, 30))).toBe("2026-10-13");
  });

  it("labels the time zone with its offset", () => {
    process.env.TZ = "America/Mexico_City";
    expect(timeZoneLabel(new Date(2026, 9, 13, 12, 0))).toBe("America/Mexico_City (UTC-06:00)");
  });
});
