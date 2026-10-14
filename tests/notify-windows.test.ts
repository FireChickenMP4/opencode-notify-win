/**
 * Which sessions stay quiet. The QQ bridge's `.bt` forks carry no parentID, so
 * the subagent rule alone misses them and every aside would toast twice.
 */

import { describe, expect, test } from "bun:test";

import { isAside, isSubagent } from "../src/notify-windows";

describe("quiet sessions", () => {
  test("a subagent is recognised by parentID", () => {
    expect(isSubagent({ parentID: "ses_p" })).toBe(true);
    expect(isSubagent({})).toBe(false);
  });

  test("a .bt aside is recognised by the bridge marker, or by its title", () => {
    expect(isAside({ metadata: { aside: true } })).toBe(true);
    expect(isAside({ title: "旁问 · 为什么构建挂了" })).toBe(true);
    expect(isAside({ title: "插件迁移升级 → v2 适配" })).toBe(false);
    expect(isAside({ title: "旁问" })).toBe(false);
  });
});
