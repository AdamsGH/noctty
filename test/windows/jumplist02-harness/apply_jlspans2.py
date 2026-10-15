"""MEASUREMENT ONLY (JUMPLIST-02, after the fix): spans around the flush.

usage: python -I apply_jlspans2.py <repo-root>   (after apply_stall.py)
Span ids: 20 startRebuild on the UI thread (copy + spawn), 21 persist,
26 the commit on the worker (RebuildJob.commit), 27 completeRebuild on the
UI thread.
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1]) / "src/apprt/win32_jump_list.zig"
s = p.read_bytes().decode("utf-8")
LT = '@import("win32/latency_trace.zig")'


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("""        if (self.rebuild_dirty and !self.com_disabled) self.startRebuild();""",
    f"""        if (self.rebuild_dirty and !self.com_disabled) {{
            const lt_rb = {LT}.qpcNow();
            self.startRebuild();
            {LT}.note(.span, {LT}.qpcNow() -| lt_rb, 20);
        }}""")
rep("""        const persisted = if (self.persist_dirty) self.persist() else true;""",
    f"""        const lt_ps = {LT}.qpcNow();
        const persisted = if (self.persist_dirty) self.persist() else true;
        {LT}.note(.span, {LT}.qpcNow() -| lt_ps, 21);""")
rep("""    pub fn run(self: *RebuildJob) void {
        self.result = self.commit();""", f"""    pub fn run(self: *RebuildJob) void {{
        const lt_c = {LT}.qpcNow();
        defer {LT}.note(.span, {LT}.qpcNow() -| lt_c, 26);
        self.result = self.commit();""")
rep("""    pub fn completeRebuild(self: *JumpList, job: *const RebuildJob) void {
""", f"""    pub fn completeRebuild(self: *JumpList, job: *const RebuildJob) void {{
        const lt_cr = {LT}.qpcNow();
        defer {LT}.note(.span, {LT}.qpcNow() -| lt_cr, 27);
""")
p.write_bytes(s.encode("utf-8"))
print("ok")
