-- Unit-Test: RefreshAccount liest Saldo (GetContext), Positionen (GetPositions) und
-- Umsätze (activityapi). FetchStatements liefert PDF-Kontoauszüge (financial-documents).

function WebBanking(_) end
ProtocolWebBanking = "WebBanking"
AccountTypePortfolio = 5
LoginFailed = "LoginFailed"

local HTML = "HTML"
local FAIL = "FAIL"
local bodies = {}
local requestBodies = {}
local calls = {}
local routes = {
  ["portfolio/api/GetContext"] = "CTX",
  ["portfolio/api/GetPositions"] = "POS",
  ["activityapi/api/v1/transactions/history"] = "TX",
  ["financial-documents/statements"] = "STMT",
  ["financial-documents/download"] = "DL",
}

local function cleanupAndExit(code)
  os.exit(code)
end

local function assertEq(actual, expected, label)
  if actual == expected then
    print("OK    " .. label .. " = " .. tostring(actual))
  else
    print("FAIL  " .. label .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    cleanupAndExit(1)
  end
end

local function assertTrue(condition, label)
  assertEq(condition and true or false, true, label)
end

local function expectError(fn, expectedText, label)
  local ok, err = pcall(fn)
  if ok then
    print("FAIL  " .. label .. ": kein Fehler")
    cleanupAndExit(1)
  end
  assertTrue(tostring(err):find(expectedText, 1, true) ~= nil, label)
end

local function routeFor(url)
  for match, key in pairs(routes) do
    if url:find(match, 1, true) then
      return key
    end
  end
  return nil
end

function Connection()
  return {
    language = "",
    useragent = "",
    setCookie = function() end,
    getCookies = function() return "" end,
    request = function(self, method, url, body, contentType, headers)
      calls[#calls + 1] = {
        url = url,
        body = requestBodies[body],
        headers = headers
      }
      local key = routeFor(url)
      if key == nil then
        error("unerwartete URL im Test: " .. tostring(url))
      end
      if key == HTML then
        return "<!DOCTYPE html><html>Login</html>", nil, "text/html"
      end
      if key == FAIL then
        error("simulierter Serverfehler")
      end
      return key, nil, "application/json; charset=utf-8"
    end,
  }
end

local statusMessages = {}
MM = {
  printStatus = function(message) statusMessages[#statusMessages + 1] = tostring(message) end,
  urlencode = function(s) return tostring(s) end,
  base64decode = function(s)
    if s ~= "UERGLTEuNA==" then
      error("unerwarteter Base64-Inhalt im Test")
    end
    return "%PDF-1.4 test"
  end,
}

local nextRequestId = 0
JSON = function(input)
  local builder = {}
  function builder:set(value)
    self.value = value
    return self
  end
  function builder:json()
    nextRequestId = nextRequestId + 1
    local key = "REQUEST#" .. tostring(nextRequestId)
    requestBodies[key] = self.value
    return key
  end
  function builder:dictionary()
    local value = bodies[input]
    if value == nil then
      error("invalid json: " .. tostring(input))
    end
    return value
  end
  return builder
end

-- Antworten der Fidelity-APIs
bodies.CTX = {
  getContext = {
    person = {
      id = "cust-1",
      assets = {
        { acctNum = "123456", acctType = "Brokerage", acctSubType = "Mutual Fund",
          gainLossBalanceDetail = { totalMarketVal = 1000.25 } },
        { acctNum = "999999", acctType = "Brokerage", acctSubType = "Mutual Fund",
          gainLossBalanceDetail = { totalMarketVal = 5 } },
      }
    }
  }
}
bodies.CTX_OTHER = { getContext = { person = { id = "cust-1", assets = { { acctNum = "999999" } } } } }
bodies.POS = {
  position = {
    acctDetails = {
      acctDetail = {
        {
          acctNum = "123456",
          positionDetails = {
            positionDetail = {
              { symbol = "FXAIX", cusip = "315911206", securityDescription = "FIDELITY 500 INDEX",
                quantity = 10, marketValDetail = { marketVal = 600.25 },
                costBasisDetail = { costBasis = 500 }, priceDetail = { lastPrice = 60.025 } },
              { symbol = "ABCDX", cusip = "", securityDescription = "SOMEFUND",
                quantity = 4, marketValDetail = { marketVal = 400 },
                costBasisDetail = { costBasis = 380 }, priceDetail = { lastPrice = 100 } },
            }
          }
        }
      }
    }
  }
}
bodies.POS_MISSING = { position = {} }
bodies.TX = {
  data = {
    transactions = {
      { txnNum = "T1", description = "YOU BOUGHT", shortDesc = "Buy", amtDetail = { net = -600.25 },
        date = 1700000000, dateDetail = { postedDate = 1700086400 } },
      { txnNum = "T0", description = "DIVIDEND", amtDetail = { net = 12.5 },
        date = 1690000000, dateDetail = { postedDate = 1690000000 } },
    }
  },
  errors = {}
}
bodies.STMT = {
  statement = {
    docDetails = {
      docDetail = {
        { id = "doc-1", acctNum = "123456", periodStartDate = 1696118400, periodEndDate = 1698796800,
          formatTypes = { formatType = { isPDF = true, isHTML = true, isCSV = false } } },
        { id = "doc-2", acctNum = "999999", periodStartDate = 1696118400, periodEndDate = 1698796800,
          formatTypes = { formatType = { isPDF = true, isHTML = true, isCSV = false } } },
      }
    }
  }
}
bodies.DL = {
  document = {
    docDetail = { contentType = "application/pdf", encoding = "Base64", deflated = "Y", content = "UERGLTEuNA==" }
  }
}

LocalStorage = {
  connectionsByAccount = {
    ["fid-refresh"] = { importedCookies = "ATC=ok; portsum_.csrf=x" },
  },
}

dofile("Fidelity.lua")

-- Wie in MoneyMoney: nur Standardfelder, keine eigenen Typ-Felder aus ListAccounts
local account = { name = "Fidelity Brokerage", accountNumber = "123456" }

local initResult = InitializeSession(ProtocolWebBanking, "Fidelity", "fid-refresh", nil, "secret", nil)
assertEq(initResult, nil, "init.sessionValid")

local function downloadCount()
  local count = 0
  for _, call in ipairs(calls) do
    if call.url:find("financial-documents/download", 1, true) then
      count = count + 1
    end
  end
  return count
end

-- 1) Vollständiger Abruf (ohne Kontoauszüge)
calls = {}
local result = RefreshAccount(account, nil)
assertEq(result.balance, 1000.25, "refresh.balanceFromGetContext")
assertEq(#result.securities, 2, "refresh.securityCount")

local fxaix = result.securities[1]
assertEq(fxaix.name, "FIDELITY 500 INDEX", "refresh.name")
assertEq(fxaix.securityNumber, "315911206", "refresh.securityNumberIsCusip")
assertEq(fxaix.quantity, 10, "refresh.quantity")
assertEq(fxaix.price, 60.025, "refresh.price")
assertEq(fxaix.amount, 600.25, "refresh.amount")
assertEq(fxaix.purchasePrice, 50, "refresh.purchasePricePerUnit")
assertEq(result.securities[2].securityNumber, "ABCDX", "refresh.securityNumberFallsBackToSymbol")

assertEq(#result.transactions, 2, "refresh.transactionCountWithoutSince")
local tx = result.transactions[1]
assertEq(tx.name, "YOU BOUGHT", "tx.name")
assertEq(tx.purpose, "Buy", "tx.purpose")
assertEq(tx.amount, -600.25, "tx.amount")
assertEq(tx.bookingDate, 1700000000, "tx.bookingDate")
assertEq(tx.valueDate, 1700086400, "tx.valueDate")
assertEq(tx.transactionCode, "T1", "tx.transactionCode")
assertEq(tx.booked, true, "tx.booked")

-- RefreshAccount lädt keine Kontoauszüge mehr
assertEq(downloadCount(), 0, "refresh.noStatementDownload")

local positionCall
local historyCall
for _, call in ipairs(calls) do
  if call.url:find("GetPositions", 1, true) then positionCall = call end
  if call.url:find("transactions/history", 1, true) then historyCall = call end
  assertTrue(not call.url:find("graphql", 1, true) and not call.url:find("performance-api", 1, true),
    "refresh.noRemovedEndpoint")
end
assertEq(positionCall.body.customerId, "cust-1", "positions.customerIdFromGetContext")
assertEq(positionCall.body.acctList[1].acctNum, "123456", "positions.accountNumber")
assertEq(positionCall.body.acctList[1].acctType, "Brokerage", "positions.acctTypeFromGetContext")
assertEq(positionCall.body.acctList[1].acctSubType, "Mutual Fund", "positions.acctSubTypeFromGetContext")
assertEq(historyCall.body.filter.accounts[1].acctNum, "123456", "history.accountNumber")

-- 2) since filtert alte Umsätze heraus
local filtered = RefreshAccount(account, 1695000000)
assertEq(#filtered.transactions, 1, "refresh.sinceFiltersOldTransactions")
assertEq(filtered.transactions[1].transactionCode, "T1", "refresh.sinceKeepsNewest")

-- 2b) since = 0 (MoneyMoney beim ersten Abruf) darf nicht als Startdatum 1970 gehen
local function historyFromDate(since)
  calls = {}
  RefreshAccount(account, since)
  for _, call in ipairs(calls) do
    if call.url:find("transactions/history", 1, true) then
      return call.body.filter.searchCriteriaDetail.txnFromDate
    end
  end
  return nil
end
local nowForTest = os.time()
local windowStart = nowForTest - 91 * 86400
local fromZero = historyFromDate(0)
assertTrue(fromZero ~= nil and fromZero >= windowStart - 60 and fromZero <= windowStart + 60, "since0.usesWindow")
local recentSince = nowForTest - 3 * 86400
assertEq(historyFromDate(recentSince), recentSince, "since.recentIsStartDate")

-- 3) FetchStatements: nur PDFs des eigenen Kontos, Kennung und Datei wie von MoneyMoney erwartet
calls = {}
local listed = FetchStatements({ account }, nil)
assertTrue(type(listed) == "table", "statements.returnsTable")
assertEq(#listed.statements, 1, "statements.onlyOwnAccount")
assertEq(downloadCount(), 1, "statements.downloadedOnce")
local downloadBody = nil
for _, call in ipairs(calls) do
  if call.url:find("financial-documents/download", 1, true) then downloadBody = call.body end
end
assertEq(downloadBody.id, "doc-1", "statements.downloadedDocIsOwnAccount")
assertEq(downloadBody.formatType, "PDF", "statements.formatPdf")

local statement = listed.statements[1]
assertEq(statement.identifier, "doc-1", "statements.identifier")
assertEq(statement.pdf, "%PDF-1.4 test", "statements.pdfDecoded")
assertEq(statement.creationDate, 1698796800, "statements.creationDateIsPeriodEnd")
assertEq(statement.filename, "Fidelity_3456_" .. os.date("%Y-%m-%d", 1696118400) .. "_"
  .. os.date("%Y-%m-%d", 1698796800) .. ".pdf", "statements.filename")

-- Bereits bekannte Kennungen werden nicht erneut geladen
calls = {}
local knownResult = FetchStatements({ account }, { "doc-1" })
assertEq(#knownResult.statements, 0, "statements.knownIdentifierSkipped")
assertEq(downloadCount(), 0, "statements.knownNotDownloadedAgain")

-- Fehler beim Laden kommt als Text zurück, damit MoneyMoney ihn anzeigt
routes["financial-documents/download"] = FAIL
local failed = FetchStatements({ account }, nil)
routes["financial-documents/download"] = "DL"
assertTrue(type(failed) == "string", "statementFailure.returnsText")
assertTrue(type(failed) == "string" and failed:find("simulierter Serverfehler", 1, true) ~= nil,
  "statementFailure.containsCause")

-- 3c) Fehler beim Umsatz-Abruf bricht den Abruf nicht ab; Saldo und Positionen kommen trotzdem an
routes["activityapi/api/v1/transactions/history"] = FAIL
statusMessages = {}
local withFailedTransactions = RefreshAccount(account, nil)
routes["activityapi/api/v1/transactions/history"] = "TX"
assertEq(withFailedTransactions.balance, 1000.25, "transactionFailure.balanceStillReturned")
assertEq(#withFailedTransactions.securities, 2, "transactionFailure.securitiesStillReturned")
assertEq(withFailedTransactions.transactions, nil, "transactionFailure.transactionsOmitted")
local transactionMessage = false
for _, message in ipairs(statusMessages) do
  if message:find("Umsätze nicht abgerufen", 1, true) and message:find("simulierter Serverfehler", 1, true) then
    transactionMessage = true
  end
end
assertTrue(transactionMessage, "transactionFailure.reportedInProtocol")

-- 4) Fehlerfälle werden klar gemeldet
routes["portfolio/api/GetContext"] = "CTX_OTHER"
expectError(function() RefreshAccount(account, nil) end, "Das Konto fehlt", "error.accountMissingInContext")
routes["portfolio/api/GetContext"] = "CTX"

routes["portfolio/api/GetPositions"] = "POS_MISSING"
expectError(function() RefreshAccount(account, nil) end, "Positionsdaten fehlen", "error.positionsMissing")
routes["portfolio/api/GetPositions"] = "POS"

routes["portfolio/api/GetPositions"] = HTML
expectError(function() RefreshAccount(account, nil) end, "Login-Seite", "error.loginPageInsteadOfData")
routes["portfolio/api/GetPositions"] = "POS"

print("ALL FIDELITY REFRESH TESTS PASSED")
cleanupAndExit(0)
