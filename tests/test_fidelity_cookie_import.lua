-- Unit-Tests für ausgewählte Logik in "Fidelity.lua" (Cookie Import Modus).
-- Stubs verhindern echte HTTP-Calls, wir prüfen aber Format/Headers.

function WebBanking(_) end

ProtocolWebBanking = "WebBanking"

-- MoneyMoney-Status/Typen, die beim Laden evtl. referenziert werden.
AccountTypePortfolio = 5
LoginFailed = "LoginFailed"

local capturedHeaders
local capturedRequest = {}

-- Stub `Connection()` wie von MoneyMoney erwartet.
function Connection()
  return {
    language = "",
    useragent = "",
    getCookies = function()
      -- Cookie import mode nutzt `getCookies()` danach nur für Tests; hier ist das nicht relevant.
      return ""
    end,
    request = function(self, method, url, body, contentType, headers)
      capturedHeaders = headers
      capturedRequest = { method = method, url = url, body = body, contentType = contentType }
      -- Erfolgreiche Session-Validierung via GraphQL
      if url and url:find("picoserver/api/graphql", 1, true) then
        return "GRAPHQL_OK", nil
      end
      -- REST-Fallback Validierung
      if url and url:find("portfolio/api/GetContext", 1, true) then
        return "GETCONTEXT_OK", nil
      end
      return "not ok", nil
    end
  }
end

MM = {
  printStatus = function(_) end,
  urlencode = function(s) return tostring(s) end
}

-- Minimaler JSON-Stub für die Fidelity-Extension-Validierung
JSON = function(input)
  if input ~= nil then
    return {
      dictionary = function()
        if input ~= "GRAPHQL_OK" and input ~= "GETCONTEXT_OK" then
          error("invalid json")
        end
        if input == "GRAPHQL_OK" then
          return {
            data = {
              getContext = {
                person = {
                  assets = {
                    {
                      acctNum = "123",
                      acctType = "Brokerage",
                      acctSubType = "Brokerage",
                      acctSubTypeDesc = "Account",
                      gainLossBalanceDetail = { totalMarketVal = "22060.27" }
                    }
                  }
                }
              }
            }
          }
        end

        return {
          totalMarketVal = 22060.27
        }
      end
    }
  end

  return {
    set = function(self, _)
      return self
    end,
    json = function()
      return "{}"
    end
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

-- Load extension (defines globals we test, including InitializeSession/SupportsBank)
dofile("Fidelity.lua")

-- SupportsBank
assertEq(SupportsBank(ProtocolWebBanking, "Fidelity"), true, "SupportsBank.fidelity")
assertEq(SupportsBank(ProtocolWebBanking, "Fidelity Investments"), true, "SupportsBank.fidelity-investments")
assertEq(SupportsBank("Other", "Fidelity"), false, "SupportsBank.wrong-protocol")
assertEq(SupportsBank(ProtocolWebBanking, "Other"), false, "SupportsBank.wrong-bank")

-- Cookie formatting: komma-separiert ohne Semikolon -> muss zu '; ' normalisiert werden
do
  capturedHeaders = nil
  capturedRequest = {}
  local result = InitializeSession(
    ProtocolWebBanking,
    "Fidelity",
    nil,
    nil,
    "COOKIE:name1=v1,name2=v2",
    nil
  )
  assertEq(result, nil, "InitializeSession.cookie-import.success")
  assertEq(capturedHeaders and capturedHeaders["Cookie"], "name1=v1; name2=v2", "InitializeSession.cookie-import.normalized-cookie-header")
end

-- Cookie formatting: trim + bereits semikolon-separiert -> unverändert
do
  capturedHeaders = nil
  local result = InitializeSession(
    ProtocolWebBanking,
    "Fidelity",
    nil,
    nil,
    "COOKIE:  a=1; b=2  ",
    nil
  )
  assertEq(result, nil, "InitializeSession.cookie-import.semicolon-separated.success")
  assertEq(capturedHeaders and capturedHeaders["Cookie"], "a=1; b=2", "InitializeSession.cookie-import.semicolon-separated.normalized")
end

-- Cookie import invalid format (kein '=')
do
  capturedHeaders = nil
  local result = InitializeSession(
    ProtocolWebBanking,
    "Fidelity",
    nil,
    nil,
    "COOKIE:abc",
    nil
  )
  assertEq(type(result), "string", "InitializeSession.cookie-import.invalid.type")
  assertEq(result, "Invalid cookie format. Use: name=value;name2=value2", "InitializeSession.cookie-import.invalid.message")
end

-- Cookie import failure: kein portfolio/Portfolio Summary im Response
do
  -- überschreibe request stub: nie "portfolio" matchen
  function Connection()
    return {
      getCookies = function() return "" end,
      request = function(self, method, url, body, contentType, headers)
        capturedHeaders = headers
        capturedRequest = { method = method, url = url }
        return "NOTHING HERE", nil
      end
    }
  end

  local result = InitializeSession(
    ProtocolWebBanking,
    "Fidelity",
    nil,
    nil,
    "COOKIE:a=1,b=2",
    nil
  )

  assertEq(type(result), "string", "InitializeSession.cookie-import.failure.string")
  assertEq(result, "Cookie import failed. Please copy fresh cookies from browser.", "InitializeSession.cookie-import.failure.message")
end

local blockedMsg = directLoginUnavailableMessage()
assertEq(type(blockedMsg), "string", "directLoginUnavailableMessage.type")
assertEq(blockedMsg:match("Cookie%-Import") ~= nil, true, "directLoginUnavailableMessage.cookieImport")
assertEq(blockedMsg:match("WebbankingBrowser") ~= nil, true, "directLoginUnavailableMessage.browser")

do
  local result = InitializeSession(
    ProtocolWebBanking,
    "Fidelity",
    "myuser",
    nil,
    "secretpass",
    nil
  )
  assertEq(type(result), "string", "InitializeSession.direct-login.blocked.type")
  assertEq(result, blockedMsg, "InitializeSession.direct-login.blocked.message")
end

print("ALL FIDELITY COOKIE-IMPORT UNIT TESTS PASSED")
