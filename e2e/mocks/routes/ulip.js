// ULIP (government logistics data: VAHAN vehicle lookup, challans, tolls).
//
// plutus-api tries ULIP first for a vehicle RC and falls back to Surepass when
// it fails; in an E2E run Surepass is the fixture-backed TestVerificationService.
// So ULIP is deliberately "down" here: login is refused, which sends every
// lookup down the fixture path.
module.exports = (route) => {
  route("POST", "/ulip/ulip/v1.0.0/user/login", () => ({
    status: 401,
    body: { error: "true", code: "401", message: "e2e mocks: ULIP is not available in E2E runs" },
  }));
};
