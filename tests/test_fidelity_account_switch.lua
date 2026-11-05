-- Regressionstest: Wechselt MoneyMoney innerhalb desselben Prozesses von Konto A zu Konto B,
-- dürfen die Sitzungs-Cookies von A nicht in die Prüfung von B gelangen.
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
    if input == "GETCONTEXT_OK" then
      return { getContext = { person = { id = "1", assets = { { acctNum = "1" } } } } }
    end
    error("invalid json")
  end
  return builder
end

local lastGraphqlCookieHeader = nil

function Connection()
  return {
    language = "",
    useragent = "",
    setCookie = function() end,
    getCookies = function() return "" end,
    request = function(self, method, url, body, contentType, headers)
      if url and url:find("portfolio/api/GetContext", 1, true) then
        lastGraphqlCookieHeader = headers and headers["Cookie"]
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

LocalStorage = {
  connectionsByAccount = {
    ["user-a"] = { importedCookies = "ATC=secret-a; ET=token-a" },
    ["user-b"] = { importedCookies = "ATC=token-b; ET=token-b-et" },
  },
}

dofile("Fidelity.lua")

local resultA = InitializeSession(ProtocolWebBanking, "Fidelity", "user-a", nil, "secret", nil)
assertEq(resultA, nil, "switch.firstAccountValid")

local resultB = InitializeSession(ProtocolWebBanking, "Fidelity", "user-b", nil, "secret", nil)
assertEq(resultB, nil, "switch.secondAccountValid")
assertEq(
  type(lastGraphqlCookieHeader) == "string" and lastGraphqlCookieHeader:find("ATC=token-b", 1, true) ~= nil,
  true,
  "switch.secondAccountUsesOwnCookies")
assertEq(
  lastGraphqlCookieHeader ~= nil and lastGraphqlCookieHeader:find("secret-a", 1, true) == nil,
  true,
  "switch.firstAccountCookiesNotLeaked")

print("ALL FIDELITY ACCOUNT SWITCH TESTS PASSED")
