"""MEASUREMENT ONLY (JUMPLIST-02): spans inside JumpList.flush.

usage: python -I apply_jlspans.py <repo-root>   (after apply_stall.py)
Span ids: 20 rebuildCom, 21 persist, 22 CoCreateInstance(DestinationList),
23 BeginList, 24 CommitList, 25 the categories (shell links).
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


rep("""        if (self.rebuild_dirty and !self.com_disabled) {
            if (self.rebuildCom()) |_| {""", f"""        if (self.rebuild_dirty and !self.com_disabled) {{
            const lt_rb = {LT}.qpcNow();
            const rb = self.rebuildCom();
            {LT}.note(.span, {LT}.qpcNow() -| lt_rb, 20);
            if (rb) |_| {{""")
rep("""        const persisted = if (self.persist_dirty) self.persist() else true;""",
    f"""        const lt_ps = {LT}.qpcNow();
        const persisted = if (self.persist_dirty) self.persist() else true;
        {LT}.note(.span, {LT}.qpcNow() -| lt_ps, 21);""")
rep("""        var raw_destination: ?*anyopaque = null;
        const create_hr = CoCreateInstance(""", f"""        var raw_destination: ?*anyopaque = null;
        const lt_cc = {LT}.qpcNow();
        const create_hr = CoCreateInstance(""")
rep("""        if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
        if (create_hr < 0 or raw_destination == null) return error.DestinationListUnavailable;""", f"""        {LT}.note(.span, {LT}.qpcNow() -| lt_cc, 22);
        if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
        if (create_hr < 0 or raw_destination == null) return error.DestinationListUnavailable;""")
rep("""        var raw_removed: ?*anyopaque = null;
        if (destination.vtbl.BeginList(""", f"""        var raw_removed: ?*anyopaque = null;
        const lt_bl = {LT}.qpcNow();
        const bl_hr = destination.vtbl.BeginList(""")
rep("""            &raw_removed,
        ) < 0) return error.BeginListFailed;""", f"""            &raw_removed,
        );
        {LT}.note(.span, {LT}.qpcNow() -| lt_bl, 23);
        if (bl_hr < 0) return error.BeginListFailed;""")
rep("""        if (destination.vtbl.CommitList(destination.asRaw()) < 0) return error.CommitListFailed;""",
    f"""        const lt_cl = {LT}.qpcNow();
        const cl_hr = destination.vtbl.CommitList(destination.asRaw());
        {LT}.note(.span, {LT}.qpcNow() -| lt_cl, 24);
        if (cl_hr < 0) return error.CommitListFailed;""")
rep("""        var visible_profile_count: usize = 0;""", f"""        const lt_cat = {LT}.qpcNow();
        defer {LT}.note(.span, {LT}.qpcNow() -| lt_cat, 25);
        var visible_profile_count: usize = 0;""")
p.write_bytes(s.encode("utf-8"))
print("ok")
