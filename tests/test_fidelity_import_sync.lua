-- Regressionstest: Nach einem Neustart muss der gespeicherte Cookie-Import in die Connection
-- zurückgeschrieben werden. Danach darf die Synchronisierung den Import nicht durch den Schnappschuss
-- von getCookies() ersetzen: der liefert nur Cookies für die zuletzt aufgerufene URL und den Server-Refresh.
-- Eigene Datei, damit Fidelity.lua mit frischem Modulzustand geladen wird.

function WebBanking(_) end

ProtocolWebBanking = "WebBanking"
AccountTypePortfolio = 5
LoginFailed = "LoginFailed"

MM = {
  printStatus = function(_) end,
  urlencode = function(s) return tostring(s) end,
}

JSON = function(input)
  local builder = {}
  function builder:set(_) return self end
  function builder:json() return "{}" end
  function builder:dictionary()
    if input == "GRAPHQL_OK" then
      return { data = { getContext = { person = { assets = { { acctNum = "1" } } } } } }
    end
    error("invalid json")
  end
  return builder
end

-- Zustandsbehafteter Cookie-Jar: setCookie schreibt in den Jar. getCookies liefert den Jar ohne die
-- Namen in urlScoped (Cookies anderer Domains/Pfade, die für die GraphQL-URL nicht gelten).
-- Bei der Sitzungsprüfung setzt der Server die Cookies aus serverSets neu.
local capturedCookieHeader = nil
local lastGraphqlCookie = nil
local jar = {}
local urlScoped = {}
local serverSets = {}

function Connection()
  return {
    language = "",
    useragent = "",
    setCookie = function(self, cookie)
      local name, value = cookie:match("^([^=]+)=(.*)$")
      jar[name] = value
    end,
    getCookies = function()
      local parts = {}
      for name, value in pairs(jar) do
        if not urlScoped[name] then
          parts[#parts + 1] = name .. "=" .. value
        end
      end
      table.sort(parts)
      return table.concat(parts, "; ")
    end,
    request = function(self, method, url, body, contentType, headers)
      capturedCookieHeader = headers and headers["Cookie"]
      if url and url:find("picoserver/api/graphql", 1, true) then
        lastGraphqlCookie = headers and headers["Cookie"]
        for name, value in pairs(serverSets) do
          jar[name] = value
        end
        return "GRAPHQL_OK", nil
      end
      return "not ok", nil
    end,
  }
end

local function assertEq(actual, expected, label)
  if actual == expected then
    print("OK    " .. label .. " = " .. tostring(actual))
  else
    print("FAIL  " .. label .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    os.exit(1)
  end
end

LocalStorage = {
  connectionAccountKey = "fid-jar",
  connectionsByAccount = {
    ["fid-jar"] = { importedCookies = "ATC=a; ET=b; OTHER=c; FC=old" },
  },
}
urlScoped = { ET = true }
serverSets = { FC = "new", ATC = "renewed" }

dofile("Fidelity.lua")

local result = InitializeSession(ProtocolWebBanking, "Fidelity", "fid-jar", nil, "secret", nil)
assertEq(result, nil, "jarSync.sessionValid")
assertEq(
  type(capturedCookieHeader) == "string" and capturedCookieHeader:find("ATC=a", 1, true) ~= nil,
  true,
  "jarSync.importSentToServer")
local stored = LocalStorage.connectionsByAccount["fid-jar"].importedCookies
assertEq(stored:find("ATC=renewed", 1, true) ~= nil, true, "jarSync.takesRenewedSessionCookie")
assertEq(stored:find("ET=b", 1, true) ~= nil, true, "jarSync.keepsUrlScopedCookie")
assertEq(stored:find("OTHER=c", 1, true) ~= nil, true, "jarSync.keepsUnchangedCookie")
assertEq(stored:find("FC=new", 1, true) ~= nil, true, "jarSync.takesServerRefresh")

-- Folge-Request der laufenden Sitzung (RefreshAccount) muss den erneuerten ATC-Wert senden.
-- Fehler danach (Antwort-Parsing des Stubs) sind hier unerheblich; geprüft wird nur der Header.
pcall(RefreshAccount, { accountNumber = "1", name = "Fidelity", accountType = "Brokerage", accountSubType = "Mutual Fund" }, nil)
assertEq(
  type(lastGraphqlCookie) == "string" and lastGraphqlCookie:find("ATC=renewed", 1, true) ~= nil,
  true,
  "jarSync.followUpUsesRenewedSessionCookie")

print("ALL FIDELITY IMPORT SYNC TESTS PASSED")
