-- Regressionstest: Cookie-Import muss einen Neustart von MoneyMoney überstehen.
-- Nach dem Neustart ist LocalStorage ohne Connection-Objekt, nur der gespeicherte Import bleibt.
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

local capturedCookieHeader = nil

function Connection()
  return {
    language = "",
    useragent = "",
    setCookie = function() end,
    getCookies = function() return "" end,
    request = function(self, method, url, body, contentType, headers)
      capturedCookieHeader = headers and headers["Cookie"]
      if url and url:find("picoserver/api/graphql", 1, true) then
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
  connectionAccountKey = "fid-restart",
  connectionsByAccount = {
    ["fid-restart"] = { importedCookies = "ATC=restart; ET=token" },
  },
}

dofile("Fidelity.lua")

local result = InitializeSession(ProtocolWebBanking, "Fidelity", "fid-restart", nil, "secret", nil)
assertEq(result, nil, "restart.sessionRestoredWithoutCookieImport")
assertEq(
  type(capturedCookieHeader) == "string" and capturedCookieHeader:find("ATC=restart", 1, true) ~= nil,
  true,
  "restart.importedCookiesSentAfterRestart")
assertEq(
  LocalStorage.connectionsByAccount["fid-restart"].importedCookies,
  "ATC=restart; ET=token",
  "restart.importKeptInStorage")
assertEq(LocalStorage.connection, nil, "restart.noConnectionInStorage")
assertEq(LocalStorage.connectionsByAccount["fid-restart"].connection, nil, "restart.noEntryConnectionInStorage")

print("ALL FIDELITY RESTART PERSISTENCE TESTS PASSED")
