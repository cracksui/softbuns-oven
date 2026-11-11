# luasql.sqlite3 stand-in for the tests, backed by Python's sqlite3
import sqlite3
def install(L):
    conns = {}
    def connect(path):
        c = sqlite3.connect(path, isolation_level=None)
        conns[id(c)] = c
        return id(c)
    def execute(cid, q):
        c = conns[cid]
        try:
            cur = c.execute(q)
        except Exception as e:
            return None, str(e)
        if cur.description is None:
            return "count", cur.rowcount
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        return "rows", L.table_from([L.table_from({k: v for k, v in r.items() if v is not None}) for r in rows])
    def close(cid):
        conns.pop(cid).close()
    L.globals().PYSQL = L.table_from({"connect": connect, "execute": execute, "close": close})
    L.execute('''
luasql = { sqlite3 = function()
  return { connect = function(self, path)
    local cid = PYSQL.connect(path)
    return {
      execute = function(self, q)
        local kind, res = PYSQL.execute(cid, q)
        if kind == nil then return nil, res end
        if kind == "count" then return res end
        local i = 0
        return { fetch = function(self, t, mode) i = i + 1 local r = res[i] if not r then return nil end
                   for k, v in pairs(r) do t[k] = v end return t end,
                 close = function() end }
      end,
      close = function() PYSQL.close(cid) end,
    }
  end }
end }''')
