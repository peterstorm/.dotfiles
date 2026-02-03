/**
 * Tests for verify-new-tests hook
 */

import { describe, it, expect } from "vitest";
import { detectNewTests, isTestFile, analyzeFilesForTests } from "./verify-new-tests.js";

// ============================================================================
// detectNewTests Tests
// ============================================================================

describe("detectNewTests", () => {
  describe("Java tests", () => {
    it("detects new @Test annotations", () => {
      const diff = `
+++ b/src/test/java/MyTest.java
@@ -10,0 +11,5 @@
+  @Test
+  void shouldDoSomething() {
+    assertEquals(1, 1);
+  }
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.count).toBeGreaterThanOrEqual(1);
      expect(result.evidence).toContain("java");
    });

    it("detects new @Property annotations (jqwik)", () => {
      const diff = `
+++ b/src/test/java/PropertyTest.java
@@ -10,0 +11,5 @@
+  @Property
+  void allNumbersArePositive(@ForAll @Positive int n) {
+    assertThat(n).isGreaterThan(0);
+  }
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("java");
    });

    it("detects new @ParameterizedTest annotations", () => {
      const diff = `
+++ b/src/test/java/ParamTest.java
@@ -10,0 +11,6 @@
+  @ParameterizedTest
+  @ValueSource(strings = {"a", "b", "c"})
+  void shouldHandle(String s) {
+    assertNotNull(s);
+  }
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("java");
    });

    it("does not count removed test annotations", () => {
      const diff = `
--- a/src/test/java/MyTest.java
+++ b/src/test/java/MyTest.java
@@ -10,5 +10,0 @@
-  @Test
-  void oldTest() {
-    assertEquals(1, 1);
-  }
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(false);
      expect(result.count).toBe(0);
    });
  });

  describe("TypeScript/JavaScript tests", () => {
    it("detects new it() blocks", () => {
      const diff = `
+++ b/src/utils.test.ts
@@ -10,0 +11,5 @@
+  it("should return true", () => {
+    expect(myFunc()).toBe(true);
+  });
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("ts/js");
    });

    it("detects new test() blocks", () => {
      const diff = `
+++ b/src/helpers.test.ts
@@ -10,0 +11,5 @@
+  test("adds numbers correctly", () => {
+    expect(add(1, 2)).toBe(3);
+  });
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("ts/js");
    });

    it("detects new describe() blocks", () => {
      const diff = `
+++ b/src/new.test.ts
@@ -0,0 +1,10 @@
+describe("NewFeature", () => {
+  it("works", () => {
+    expect(true).toBe(true);
+  });
+});
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.count).toBeGreaterThanOrEqual(1);
    });

    it("does not count removed test blocks", () => {
      const diff = `
--- a/src/old.test.ts
+++ b/src/old.test.ts
@@ -10,5 +10,0 @@
-  it("old test", () => {
-    expect(1).toBe(1);
-  });
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(false);
      expect(result.count).toBe(0);
    });
  });

  describe("Python tests", () => {
    it("detects new def test_ functions", () => {
      const diff = `
+++ b/tests/test_main.py
@@ -10,0 +11,3 @@
+def test_addition():
+    assert add(1, 2) == 3
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("python");
    });

    it("detects new Test classes", () => {
      const diff = `
+++ b/tests/test_feature.py
@@ -0,0 +1,6 @@
+class TestFeature:
+    def test_something(self):
+        assert True
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.evidence).toContain("python");
    });
  });

  describe("mixed languages", () => {
    it("counts tests from multiple languages", () => {
      const diff = `
+++ b/src/utils.test.ts
+  it("typescript test", () => {
+    expect(true).toBe(true);
+  });
+++ b/src/test/java/MyTest.java
+  @Test
+  void javaTest() {
+    assertEquals(1, 1);
+  }
+++ b/tests/test_main.py
+def test_python():
+    assert True
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(true);
      expect(result.count).toBe(3);
      expect(result.evidence).toContain("ts/js");
      expect(result.evidence).toContain("java");
      expect(result.evidence).toContain("python");
    });
  });

  describe("edge cases", () => {
    it("returns written: false for empty diff", () => {
      const result = detectNewTests("");
      expect(result.written).toBe(false);
      expect(result.count).toBe(0);
    });

    it("returns written: false for diff with no tests", () => {
      const diff = `
+++ b/src/index.ts
@@ -10,0 +11,3 @@
+export function add(a: number, b: number): number {
+  return a + b;
+}
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(false);
      expect(result.count).toBe(0);
    });

    it("ignores test-like strings in non-added lines", () => {
      const diff = `
 // This is a comment mentioning @Test
 // it("should not count this")
+// Real added line without test
`;

      const result = detectNewTests(diff);
      expect(result.written).toBe(false);
      expect(result.count).toBe(0);
    });
  });
});

// ============================================================================
// isTestFile Tests
// ============================================================================

describe("isTestFile", () => {
  describe("TypeScript/JavaScript", () => {
    it("matches .test.ts files", () => {
      expect(isTestFile("src/utils.test.ts")).toBe(true);
      expect(isTestFile("components/Button.test.tsx")).toBe(true);
    });

    it("matches .spec.ts files", () => {
      expect(isTestFile("src/utils.spec.ts")).toBe(true);
      expect(isTestFile("components/Button.spec.tsx")).toBe(true);
    });

    it("matches .test.js files", () => {
      expect(isTestFile("src/utils.test.js")).toBe(true);
      expect(isTestFile("src/utils.test.jsx")).toBe(true);
    });

    it("matches __tests__ directory", () => {
      expect(isTestFile("src/__tests__/utils.ts")).toBe(true);
      expect(isTestFile("components/__tests__/Button.tsx")).toBe(true);
    });

    it("does not match regular source files", () => {
      expect(isTestFile("src/utils.ts")).toBe(false);
      expect(isTestFile("components/Button.tsx")).toBe(false);
    });
  });

  describe("Java", () => {
    it("matches Test.java files", () => {
      expect(isTestFile("src/test/java/MyTest.java")).toBe(true);
      expect(isTestFile("FeatureTest.java")).toBe(true);
    });

    it("matches IT.java files (integration tests)", () => {
      expect(isTestFile("src/test/java/MyIT.java")).toBe(true);
    });

    it("matches src/test/ directory", () => {
      expect(isTestFile("src/test/java/com/example/MyClass.java")).toBe(true);
    });

    it("does not match regular Java source files", () => {
      expect(isTestFile("src/main/java/MyClass.java")).toBe(false);
    });
  });

  describe("Kotlin", () => {
    it("matches Test.kt files", () => {
      expect(isTestFile("src/test/kotlin/MyTest.kt")).toBe(true);
    });

    it("matches Tests.kt files", () => {
      expect(isTestFile("src/test/kotlin/MyTests.kt")).toBe(true);
    });
  });

  describe("Python", () => {
    it("matches test_*.py files", () => {
      expect(isTestFile("tests/test_main.py")).toBe(true);
      expect(isTestFile("test_utils.py")).toBe(true);
    });

    it("matches *_test.py files", () => {
      expect(isTestFile("tests/main_test.py")).toBe(true);
      expect(isTestFile("utils_test.py")).toBe(true);
    });

    it("does not match regular Python files", () => {
      expect(isTestFile("src/main.py")).toBe(false);
      expect(isTestFile("utils.py")).toBe(false);
    });
  });
});

// ============================================================================
// analyzeFilesForTests Tests
// ============================================================================

describe("analyzeFilesForTests", () => {
  it("counts tests in TypeScript test files", () => {
    const files = [
      {
        path: "src/utils.test.ts",
        content: `
          describe("Utils", () => {
            it("should work", () => {});
            it("should also work", () => {});
            test("another test", () => {});
          });
        `,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(true);
    expect(result.count).toBe(4); // 1 describe + 2 it + 1 test
  });

  it("counts tests in Java test files", () => {
    const files = [
      {
        path: "src/test/java/MyTest.java",
        content: `
          @Test
          void testOne() {}
          
          @Test
          void testTwo() {}
          
          @Property
          void propertyTest() {}
        `,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(true);
    expect(result.count).toBe(3); // 2 @Test + 1 @Property
  });

  it("counts tests in Python test files", () => {
    const files = [
      {
        path: "tests/test_main.py",
        content: `
          class TestFeature:
              def test_one(self):
                  pass
              def test_two(self):
                  pass
        `,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(true);
    expect(result.count).toBe(3); // 1 class Test + 2 def test_
  });

  it("ignores non-test files", () => {
    const files = [
      {
        path: "src/main.ts",
        content: `
          // This file has test-like patterns but isn't a test file
          const test = () => {};
          describe("not a test", () => {});
        `,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(false);
    expect(result.count).toBe(0);
  });

  it("handles empty file list", () => {
    const result = analyzeFilesForTests([]);
    expect(result.written).toBe(false);
    expect(result.count).toBe(0);
  });

  it("handles files with no tests", () => {
    const files = [
      {
        path: "src/utils.test.ts",
        content: `
          // Empty test file
          export {};
        `,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(false);
    expect(result.count).toBe(0);
  });

  it("combines tests from multiple files", () => {
    const files = [
      {
        path: "src/a.test.ts",
        content: `it("test 1", () => {});`,
      },
      {
        path: "src/b.test.ts",
        content: `it("test 2", () => {}); it("test 3", () => {});`,
      },
    ];

    const result = analyzeFilesForTests(files);
    expect(result.written).toBe(true);
    expect(result.count).toBe(3);
  });
});
