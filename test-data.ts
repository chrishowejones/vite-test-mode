// This is a manual test fixture for trying out vite-test-unit-at-point
describe("foo", () => {
  test("bar ^s", () => {
    test("wahooo!", () => {});
  });

  it("hello world", () => {});

  it("hello world", () => {});

  it.concurrently("foo bar", () => {});
});
