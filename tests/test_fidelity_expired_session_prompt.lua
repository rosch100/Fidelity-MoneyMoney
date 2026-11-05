-- Regressionstest: Ist die gespeicherte Sitzung abgelaufen, muss MoneyMoney das Passwortfeld
-- zeigen (LoginFailed), damit frische Cookies eingegeben werden können.
-- Vorher kam nur ein Fehlertext zurück, ohne Passwortabfrage.
-- Netzwerkausfall bleibt eine eigene Meldung, weil die Sitzung dann nicht als abgelaufen gilt.

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
    if input == "GETCONTEXT_OK" then
      return { getContext = { person = { id = "1", assets = { { acctNum = "1" } } } } }
    end
    error("invalid json")
  end
  return builder
end

local networkMode = false

function Connection()
  return {
    language = "",
    useragent = "",
    setCookie = function() end,
    getCookies = function() return "" end,
    request = function(self, method, url, body, contentType, headers)
      if networkMode then
        return nil, "timeout"
      end
      local cookie = headers and headers["Cookie"] or ""
      if cookie:find("ATC=new", 1, true) then
        return "GETCONTEXT_OK", nil
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

LocalStorage = { connectionsByAccount = {} }

dofile("Fidelity.lua")

local function storeExpiredImport(accountKey)
  LocalStorage.connectionsByAccount[accountKey] = { importedCookies = "ATC=old; ET=old" }
end

-- 1) Abgelaufene Sitzung, normales Passwort: Passwortabfrage statt Fehlertext
do
  storeExpiredImport("fid-expired-plain")
  local result = InitializeSession(ProtocolWebBanking, "Fidelity", "fid-expired-plain", nil, "secret", nil)
  assertEq(result, LoginFailed, "expired.plainPassword.asksForPassword")
end

-- 2) Abgelaufene Sitzung, neuer COOKIE-Import schlägt fehl: erneut Passwortabfrage
do
  storeExpiredImport("fid-expired-bad-import")
  local result = InitializeSession(
    ProtocolWebBanking, "Fidelity", "fid-expired-bad-import", nil, "COOKIE:ATC=bad; ET=bad", nil)
  assertEq(result, LoginFailed, "expired.badImport.asksForPasswordAgain")
end

-- 3) Abgelaufene Sitzung, neuer COOKIE-Import gelingt: Sitzung gilt, Import wird gespeichert
do
  storeExpiredImport("fid-expired-ok")
  local result = InitializeSession(
    ProtocolWebBanking, "Fidelity", "fid-expired-ok", nil, "COOKIE:ATC=new; ET=new", nil)
  assertEq(result, nil, "expired.goodImport.loggedIn")
  assertEq(
    LocalStorage.connectionsByAccount["fid-expired-ok"].importedCookies,
    "ATC=new; ET=new",
    "expired.goodImport.importStored")
end

-- 4) Netzwerkausfall bei der Sitzungsprüfung: keine Passwortabfrage, sondern Erreichbarkeitsmeldung
do
  storeExpiredImport("fid-network")
  networkMode = true
  local result = InitializeSession(ProtocolWebBanking, "Fidelity", "fid-network", nil, "secret", nil)
  networkMode = false
  assertEq(type(result), "string", "network.returnsMessage")
  assertEq(
    result:find("nicht erreichbar", 1, true) ~= nil,
    true,
    "network.unreachableMessage")
end

print("ALL FIDELITY EXPIRED SESSION PROMPT TESTS PASSED")
