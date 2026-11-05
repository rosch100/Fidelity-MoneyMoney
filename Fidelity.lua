--
-- Plugin Homepage: https://github.com/rosch100/Fidelity-MoneyMoney
-- Fidelity Investments — MoneyMoney Web Banking Extension (Beta 0.92, Cookie-Import)
-- https://www.fidelity.com
-- Dokumentation: README.md (Hub: https://github.com/rosch100/moneymoney-extensions)
-- API: https://moneymoney.app/api/webbanking/
--

WebBanking{
  version     = 0.93,
  url         = "https://www.fidelity.com",
  services    = {"Fidelity"},
  description = "Fidelity Investments — Beta (Cookie-Import)"
}

local CONSTANTS = {
  portfolioSummary = "https://digital.fidelity.com/ftgw/digital/portfolio/summary",
  portfolioGetContextApi = "https://digital.fidelity.com/ftgw/digital/portfolio/api/GetContext",
  positionsApi = "https://digital.fidelity.com/ftgw/digital/portfolio/api/GetPositions",
  activityHistoryApi = "https://digital.fidelity.com/ftgw/digital/activityapi/api/v1/transactions/history",
  activityHeaders = {
    ["appId"] = "ap182468",
    ["appName"] = "activity-orders-ui",
    ["Referer"] = "https://digital.fidelity.com/ftgw/digital/portfolio/activity"
  },
  statementsApi = "https://digitalservices.fidelity.com/ftgw/dp/retail-am-financialdoc/v1/accounts/communications/financial-documents/statements",
  documentDownloadApi = "https://digitalservices.fidelity.com/ftgw/dp/retail-am-financialdoc/v2/accounts/communications/financial-documents/download",
  documentHeaders = {
    ["AppId"] = "AP160308",
    ["AppName"] = "Document Access Hub",
    ["FID-ORIGINATING-APP-ID"] = "AP160308",
    ["FID-ORIGINATING-APP-VERSION"] = "2",
    ["Origin"] = "https://digitalservices.fidelity.com",
    ["Referer"] = "https://digitalservices.fidelity.com/navigate/ent-documentcenter/statements?poe=fidcom"
  },
  transactionLookbackDays = 91,
  statementLookbackDays = 365,
  logoutUrl = "https://www.fidelity.com/logout"
}

local connection
-- Connection-Objekte je Benutzername, nur für die Laufzeit (nicht in LocalStorage).
local liveConnections = {}

-- Schreibt einen Cookie-String ("a=1; b=2") in den Cookie-Jar der Connection.
local function applyCookieStringToConnection(cookieString)
  if type(connection.setCookie) ~= "function" then
    error("Fidelity: Connection:setCookie fehlt, Cookies können nicht gesetzt werden.")
  end
  for pair in cookieString:gmatch("[^;]+") do
    local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if name then
      connection:setCookie(name .. "=" .. value)
    end
  end
end

local session = { cookies = "", persistedConnection = false }

local function extractCookieValue(cookieString, cookieName)
  if not cookieString or cookieString == "" or not cookieName or cookieName == "" then
    return nil
  end

  -- Cookie-Format ist i.d.R. "a=b; c=d". Wir parsen robust via Split & Key-Vergleich.
  for part in cookieString:gmatch("([^;]+)") do
    -- trim
    local token = part:match("^%s*(.-)%s*$")
    if token and token ~= "" then
      local k, v = token:match("^([^=]+)=(.*)$")
      if k and v and k == cookieName then
        local trimmedV = v:match("^%s*(.-)%s*$")
        if trimmedV and trimmedV ~= "" then
          return trimmedV
        end
        return nil
      end
    end
  end

  return nil
end

local function trimCookiePart(value)
  if value == nil then
    return ""
  end
  return tostring(value):match("^%s*(.-)%s*$")
end

-- Cookie Header-Merging:
-- - bestehende Session-Cookies bleiben erhalten
-- - neue Cookies überschreiben nur den jeweiligen Cookie-Wert (per Name)
-- - Cookie-Reihenfolge bleibt möglichst stabil (erst vorhandene, dann neue)
local function mergeCookies(existingCookies, newCookies)
  existingCookies = existingCookies or ""
  newCookies = newCookies or ""
  if existingCookies == "" then
    return newCookies
  end
  if newCookies == "" then
    return existingCookies
  end

  local existingParts = {}
  local existingIndex = {}
  for part in existingCookies:gmatch("([^;]+)") do
    local token = trimCookiePart(part)
    if token ~= "" then
      local k, v = token:match("^([^=]+)=(.*)$")
      k = trimCookiePart(k)
      v = trimCookiePart(v)
      if k ~= "" then
        existingIndex[k] = #existingParts + 1
        existingParts[#existingParts + 1] = { name = k, value = v }
      end
    end
  end

  local newMap = {}
  local newOrder = {}
  local newIndex = {}
  for part in newCookies:gmatch("([^;]+)") do
    local token = trimCookiePart(part)
    if token ~= "" then
      local k, v = token:match("^([^=]+)=(.*)$")
      k = trimCookiePart(k)
      v = trimCookiePart(v)
      if k ~= "" and v ~= "" then
        newMap[k] = v
        if newIndex[k] == nil then
          newIndex[k] = true
          newOrder[#newOrder + 1] = k
        end
      end
    end
  end

  -- Update vorhandene Teile.
  for i = 1, #existingParts do
    local name = existingParts[i].name
    if newMap[name] ~= nil then
      existingParts[i].value = newMap[name]
    end
  end

  -- Neue Cookie-Namen anhängen.
  for i = 1, #newOrder do
    local name = newOrder[i]
    if existingIndex[name] == nil then
      existingParts[#existingParts + 1] = { name = name, value = newMap[name] }
    end
  end

  local merged = {}
  for i = 1, #existingParts do
    merged[i] = existingParts[i].name .. "=" .. existingParts[i].value
  end

  return table.concat(merged, "; ")
end

local function isAuthenticatedViaPortfolioGetContext()
  if not session.cookies or session.cookies == "" then
    return false
  end

  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary
  }

  local response, _, mimeType = connection:request(
    "POST",
    CONSTANTS.portfolioGetContextApi,
    JSON():set({}):json(),
    "application/json",
    headers
  )

  if not response or type(response) ~= "string" then
    return nil
  end

  if response:find("<!doctype html", 1, false) or (mimeType and mimeType:find("html")) then
    return false
  end

  local success, data = pcall(function() return JSON(response):dictionary() end)
  if not success or not data then
    return false
  end

  -- Typical HAR contains totalMarketVal and/or assets-containing context.
  if data.totalMarketVal ~= nil then
    return true
  end

  if data.getContext and data.getContext.person and data.getContext.person.assets then
    return type(data.getContext.person.assets) == "table"
  end

  return false
end

-- true: Sitzung gültig. false: Server meldet die Sitzung als ungültig.
-- nil: keine Antwort von beiden Prüfungen (Netzwerkfehler), Cookies nicht anfordern.
local function isAuthenticated()
  return isAuthenticatedViaPortfolioGetContext()
end

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and (bankCode == "Fidelity" or bankCode == "Fidelity Investments")
end

function restoreImportedCookies(accountKey)
  local storage = rawget(_G, "LocalStorage")
  if not storage or not storage.connectionsByAccount then
    return
  end
  local entry = storage.connectionsByAccount[accountKey]
  if entry and type(entry.importedCookies) == "string" and entry.importedCookies ~= "" then
    -- Importierte Cookies sind nur die Basis; frischere Werte der Connection gewinnen.
    session.cookies = mergeCookies(entry.importedCookies, session.cookies)
  end
end

-- Nach erfolgreicher Sitzungsprüfung den gespeicherten Import mit den Cookies der Connection aktualisieren.
-- Neue Werte ersetzen die gespeicherten, übrige Cookies bleiben erhalten. Ein vollständiger Ersatz
-- würde Cookies verwerfen, die getCookies() für die zuletzt aufgerufene URL nicht liefert.
function syncImportedCookies(accountKey)
  local storage = rawget(_G, "LocalStorage")
  if not storage or not storage.connectionsByAccount or not connection then
    return
  end
  local entry = storage.connectionsByAccount[accountKey]
  local current = connection:getCookies() or ""
  if entry and type(entry.importedCookies) == "string" and entry.importedCookies ~= "" and current ~= "" then
    entry.importedCookies = mergeCookies(entry.importedCookies, current)
  end
end

function persistImportedCookies(cookieString)
  local storage = rawget(_G, "LocalStorage")
  if not storage then
    error("Fidelity: LocalStorage nicht verfügbar, Cookies können nicht gespeichert werden.")
  end
  local accountKey = storage.connectionAccountKey or ""
  storage.connectionsByAccount = storage.connectionsByAccount or {}
  local entry = storage.connectionsByAccount[accountKey]
  if not entry then
    entry = {}
    storage.connectionsByAccount[accountKey] = entry
  end
  entry.importedCookies = cookieString
  applyCookieStringToConnection(cookieString)
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  local storage = rawget(_G, "LocalStorage")
  local accountKey = username or ""

  -- `session` lebt im Modul und überdauert den Kontowechsel: Cookies des vorherigen Kontos verwerfen.
  if session.accountKey ~= accountKey then
    session.cookies = ""
    session.accountKey = accountKey
  end

  if storage then
    storage.connectionsByAccount = storage.connectionsByAccount or {}
    -- Connection-Objekte gehören nicht in LocalStorage: MoneyMoney serialisiert sie beim Beenden nicht,
    -- der gespeicherte Cookie-Import (importedCookies) würde sonst mit verloren gehen.
    -- Frühere Versionen haben sie dort abgelegt; sie werden hier entfernt.
    storage.connection = nil
    local entry = storage.connectionsByAccount[accountKey] or {}
    entry.connection = nil
    storage.connectionsByAccount[accountKey] = entry
    storage.connectionAccountKey = accountKey
    connection = liveConnections[accountKey]
    if connection == nil then
      connection = Connection()
      liveConnections[accountKey] = connection
      -- Neue Connection (z. B. nach einem Neustart): gespeicherten Import in den Jar übernehmen,
      -- damit der Jar den vollständigen Import enthält, bevor er zurückgeschrieben wird.
      if type(entry.importedCookies) == "string" and entry.importedCookies ~= "" then
        applyCookieStringToConnection(entry.importedCookies)
      end
    end
    session.persistedConnection = true
  else
    connection = Connection()
    session.persistedConnection = false
  end

  -- Apply in case we reused an existing connection object.
  connection.language = "en-US"
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

  restoreImportedCookies(accountKey)

  -- If persisted cookies are still valid, skip the bot-protected login flow.
  session.cookies = mergeCookies(session.cookies, connection:getCookies() or "")
  local storedSessionChecked = false
  local storedSessionValid = nil
  if session.cookies ~= "" and (session.cookies:match("ATC") or session.cookies:match("ET")) then
    storedSessionChecked = true
    storedSessionValid = isAuthenticated()
    if storedSessionValid == true then
      -- Vom Server erneuerte Cookies (z. B. ATC) auch für Folge-Requests dieser Sitzung übernehmen.
      session.cookies = mergeCookies(session.cookies, connection:getCookies() or "")
      syncImportedCookies(accountKey)
      return nil
    end
  end

  -- Gespeicherte Sitzung ist abgelaufen (nicht nur nicht erreichbar): LoginFailed zeigt MoneyMoney
  -- das Passwortfeld, damit frische Cookies eingegeben werden.
  local storedSessionExpired = storedSessionValid == false

  if password and password:match("^COOKIE:") then
    local importError = loginWithImportedCookies(password:sub(8))
    if importError == nil or not storedSessionExpired then
      return importError
    end
    -- Das gespeicherte Passwort ist bei abgelaufener Sitzung meist der alte Cookie-String.
    return LoginFailed
  end

  if storedSessionExpired then
    return LoginFailed
  end

  if storedSessionChecked and storedSessionValid == nil then
    return "Fidelity ist gerade nicht erreichbar. Bitte in einigen Minuten erneut versuchen."
  end

  if username == "" or password == "" or username == nil or password == nil then
    return "Cookie-Import erforderlich: Passwort = COOKIE:ATC=...;ET=...\n\n"
      .. directLoginUnavailableMessage()
  end

  return directLoginUnavailableMessage()
end

function directLoginUnavailableMessage()
  return "Direct-Login (Username/Passwort) ist in Lua ohne Browser-Runtime nicht möglich.\n\n"
    .. "Fidelity schützt die Login-API (ecaap.fidelity.com) mit Akamai Bot Manager "
    .. "(_abck, bm_* Cookies) und Multi-Faktor-Authentifizierung — "
    .. "nicht nachbaubar per reinem HTTP.\n\n"
    .. "Cookie-Import (empfohlen):\n"
    .. "1. Im Browser bei digital.fidelity.com einloggen (inkl. MFA)\n"
    .. "2. Cookies exportieren (HAR oder Tampermonkey)\n"
    .. "3. MoneyMoney Passwort: COOKIE:ATC=...;ET=...\n\n"
    .. "HAR: python3 scripts/extract-fidelity-cookies.py login.har\n\n"
    .. "Für Direct-Login fehlt die Engine-API WebbankingBrowser.\n"
    .. "Details: https://github.com/rosch100/moneymoney-extensions/blob/main/docs/ENGINE-API-GAPS.md"
end

function loginWithImportedCookies(cookieString)
  MM.printStatus("Using imported cookies...")

  -- Convert comma-separated to semicolon-separated if needed
  local formattedCookies = cookieString:gsub("^%s*(.-)%s*$", "%1")
  if formattedCookies:match(",") and not formattedCookies:match(";") then
    formattedCookies = formattedCookies:gsub("%s*,%s*", "; ")
  end

  if not formattedCookies:match("=") then
    return "Invalid cookie format. Use: name=value;name2=value2"
  end

  session.cookies = formattedCookies

  if isAuthenticated() then
    MM.printStatus("Cookie import successful")
    persistImportedCookies(formattedCookies)
    return nil
  end

  return "Cookie import failed. Please copy fresh cookies from browser."
end

function ListAccounts(knownAccounts)
  MM.printStatus("Fetching Fidelity accounts...")
  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary
  }

  local response, _, mimeType = connection:request(
    "POST",
    CONSTANTS.portfolioGetContextApi,
    JSON():set({}):json(),
    "application/json",
    headers
  )
  local newCookies = connection:getCookies() or ""
  if newCookies ~= "" and extractCookieValue(newCookies, "portsum_.csrf") then
    session.cookies = mergeCookies(session.cookies, newCookies)
  end

  if not response or type(response) ~= "string" or (mimeType and mimeType:find("html")) then
    return "Failed to fetch accounts"
  end

  local accounts = {}
  local success, data = pcall(function() return JSON(response):dictionary() end)
  local person = data and data.getContext and data.getContext.person or nil
  local assets = person and person.assets or nil

  if success and assets and type(assets) == "table" then
    for _, acc in ipairs(assets) do
      local acctTypeDesc = acc.acctSubTypeDesc or acc.acctType or "Account"
      table.insert(accounts, {
        name = "Fidelity " .. acctTypeDesc,
        accountNumber = acc.acctNum,
        accountType = acc.acctType or "Brokerage",
        accountSubType = acc.acctSubType or "Mutual Fund",
        portfolio = true,
        currency = "USD",
        type = AccountTypePortfolio,
        bankCode = "Fidelity"
      })
    end
  end

  if #accounts == 0 then
    return "No accounts found"
  end

  return accounts
end

local function resolveSecurityPrice(price, quantity, marketValue)
  local resolved = tonumber(price)
  if resolved == nil and quantity and quantity > 0 and marketValue then
    resolved = marketValue / quantity
  end
  return resolved
end

local function buildSecurity(fields)
  if type(fields.name) ~= "string" or fields.name == ""
      or type(fields.symbol) ~= "string" or fields.symbol == ""
      or fields.quantity == nil or fields.price == nil or fields.marketValue == nil then
    return nil
  end

  local securityNumber = fields.cusip
  if type(securityNumber) ~= "string" or securityNumber == "" then
    securityNumber = fields.symbol
  end

  local security = {
    name = fields.name,
    securityNumber = securityNumber,
    quantity = fields.quantity,
    price = fields.price,
    amount = fields.marketValue,
    currencyOfPrice = "USD",
    currencyOfOriginalAmount = "USD"
  }
  if fields.purchasePrice ~= nil then
    security.purchasePrice = fields.purchasePrice
  end
  return security
end

-- Gemeinsamer Abruf der Fidelity-APIs mit der Cookie-Sitzung. Liefert die JSON-Antwort als Tabelle.
local function postJson(url, body, extraHeaders)
  local headers = {
    ["Accept"] = "application/json, text/plain, */*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary
  }
  for name, value in pairs(extraHeaders or {}) do
    headers[name] = value
  end

  local encodedBody = JSON():set(body):json()
  local response, _, mimeType = connection:request(
    "POST",
    url,
    encodedBody,
    "application/json",
    headers
  )

  local newCookies = connection:getCookies() or ""
  if newCookies ~= "" and extractCookieValue(newCookies, "portsum_.csrf") then
    session.cookies = mergeCookies(session.cookies, newCookies)
  end

  if type(response) ~= "string" or response == "" then
    error("Fidelity: Keine Serverantwort von " .. url .. ".")
  end

  local head = response:sub(1, 300):lower()
  if head:find("<!doctype html", 1, true) or head:find("<html", 1, true)
      or (mimeType and mimeType:find("html")) then
    error("Fidelity: Login-Seite statt Daten erhalten. Die Sitzung ist abgelaufen; bitte Cookies erneut importieren.")
  end

  local success, data = pcall(function() return JSON(response):dictionary() end)
  if not success or type(data) ~= "table" then
    error("Fidelity: Ungültige Serverantwort von " .. url .. ".")
  end
  if type(data.status) == "number" and data.status >= 400 then
    error("Fidelity: Serverfehler HTTP " .. tostring(data.status) .. " von " .. url .. ".")
  end
  return data
end

local function fetchContext()
  local data = postJson(CONSTANTS.portfolioGetContextApi, {})
  local person = data.getContext and data.getContext.person
  if type(person) ~= "table" or type(person.id) ~= "string" or type(person.assets) ~= "table" then
    error("Fidelity: GetContext enthält keine Kundendaten oder Konten.")
  end
  return person
end

local function findAsset(person, accountNumber)
  for _, asset in ipairs(person.assets) do
    if asset.acctNum == accountNumber then
      return asset
    end
  end
  error("Fidelity: Das Konto fehlt in GetContext.")
end

local function accountTotal(asset)
  local detail = asset.gainLossBalanceDetail
  local total = type(detail) == "table" and tonumber(detail.totalMarketVal) or nil
  if total == nil then
    error("Fidelity: Gesamtwert des Kontos fehlt in GetContext.")
  end
  return total
end

local function fetchPositions(account, customerId)
  local data = postJson(CONSTANTS.positionsApi, {
    acctList = {
      {
        acctNum = account.accountNumber,
        acctType = account.accountType,
        acctSubType = account.accountSubType,
        preferenceDetail = false
      }
    },
    customerId = customerId
  })
  local acctDetails = data.position and data.position.acctDetails and data.position.acctDetails.acctDetail
  if type(acctDetails) ~= "table" then
    error("Fidelity: Positionsdaten fehlen in der Serverantwort.")
  end
  return acctDetails
end

local function buildPositions(acctDetails, accountNumber)
  local securities = {}
  for _, acctDetail in ipairs(acctDetails) do
    if acctDetail.acctNum == accountNumber then
      local positions = acctDetail.positionDetails and acctDetail.positionDetails.positionDetail
      if type(positions) ~= "table" then
        error("Fidelity: Positionsliste fehlt in der Serverantwort.")
      end
      for _, position in ipairs(positions) do
        local quantity = tonumber(position.quantity)
        local marketValue = position.marketValDetail and tonumber(position.marketValDetail.marketVal)
        local costBasis = position.costBasisDetail and tonumber(position.costBasisDetail.costBasis)
        local lastPrice = position.priceDetail and tonumber(position.priceDetail.lastPrice)
        -- costBasis ist der Gesamteinstand; MoneyMoney erwartet den Einstandspreis je Stück.
        local purchasePrice = costBasis and quantity and quantity > 0 and costBasis / quantity or nil
        local security = buildSecurity({
          name = position.securityDescription,
          symbol = position.symbol,
          cusip = position.cusip,
          quantity = quantity,
          price = resolveSecurityPrice(lastPrice, quantity, marketValue),
          marketValue = marketValue,
          purchasePrice = purchasePrice
        })
        if not security then
          error("Fidelity: Serverantwort enthält mindestens eine unvollständige Position.")
        end
        table.insert(securities, security)
      end
    end
  end
  return securities
end

local function fetchTransactions(account, since, nowTimestamp)
  -- MoneyMoney liefert beim ersten Abruf since = 0. since gilt nur als Untergrenze, wenn es
  -- jünger als das Zeitfenster ist; sonst bleibt das Zeitfenster maßgeblich.
  local fromTimestamp = nowTimestamp - CONSTANTS.transactionLookbackDays * 86400
  if since ~= nil and since > fromTimestamp then
    fromTimestamp = since
  end
  local data = postJson(CONSTANTS.activityHistoryApi, {
    filter = {
      accounts = {
        { acctNum = account.accountNumber, acctName = account.name, acctType = account.accountType }
      },
      searchCriteriaDetail = {
        txnFromDate = fromTimestamp,
        txnToDate = nowTimestamp,
        includeBasketNames = false,
        includeCoreFundSettlementTransactions = false,
        includeFullyPaidLendingTxn = false
      }
    }
  }, CONSTANTS.activityHeaders)

  local history = data.data and data.data.transactions
  if type(history) ~= "table" then
    error("Fidelity: Umsatzdaten fehlen in der Serverantwort.")
  end

  local transactions = {}
  for _, tx in ipairs(history) do
    local amount = tx.amtDetail and tonumber(tx.amtDetail.net)
    local bookingDate = tonumber(tx.date)
    local valueDate = tx.dateDetail and tonumber(tx.dateDetail.postedDate)
    if amount == nil or bookingDate == nil or valueDate == nil or type(tx.description) ~= "string" then
      error("Fidelity: Umsatz ohne Betrag, Datum oder Beschreibung in der Serverantwort.")
    end
    if since == nil or bookingDate >= since then
      table.insert(transactions, {
        name = tx.description,
        purpose = type(tx.shortDesc) == "string" and tx.shortDesc or nil,
        transactionCode = tx.txnNum,
        amount = amount,
        currency = "USD",
        bookingDate = bookingDate,
        valueDate = valueDate,
        booked = true
      })
    end
  end
  return transactions
end

local function hasPdfFormat(document)
  local formats = document.formatTypes and document.formatTypes.formatType
  return type(formats) == "table" and formats.isPDF == true
end

local function downloadStatement(document, account)
  local data = postJson(CONSTANTS.documentDownloadApi, {
    id = document.id,
    formatType = "PDF",
    docType = "STMT",
    acctType = account.accountType
  }, CONSTANTS.documentHeaders)

  local detail = data.document and data.document.docDetail
  if type(detail) ~= "table" or detail.contentType ~= "application/pdf"
      or detail.encoding ~= "Base64" or type(detail.content) ~= "string" then
    error("Fidelity: Kontoauszug hat ein unerwartetes Format.")
  end

  -- Der Inhalt ist nach dem Base64-Dekodieren direkt die PDF-Datei (Flag "deflated" ist nicht relevant).
  local pdf = MM.base64decode(detail.content)
  if pdf:sub(1, 4) ~= "%PDF" then
    error("Fidelity: Der Kontoauszug ist keine gültige PDF-Datei.")
  end
  return pdf
end

-- Liefert die PDF-Kontoauszüge des Kontos, deren Kennung MoneyMoney noch nicht kennt.
local function fetchNewStatements(accountInfo, knownSet)
  local nowTimestamp = os.time()
  local data = postJson(CONSTANTS.statementsApi, {
    docType = "STMT",
    startDate = os.date("%Y-%m-%d", nowTimestamp - CONSTANTS.statementLookbackDays * 86400),
    endDate = os.date("%Y-%m-%d", nowTimestamp),
    filterText = "",
    hasCryptoAccount = false
  }, CONSTANTS.documentHeaders)

  local documents = data.statement and data.statement.docDetails and data.statement.docDetails.docDetail
  if type(documents) ~= "table" then
    error("Fidelity: Dokumentenliste fehlt in der Serverantwort.")
  end

  local statements = {}
  for _, document in ipairs(documents) do
    if document.acctNum == accountInfo.accountNumber and hasPdfFormat(document) then
      if type(document.id) ~= "string" or document.id == "" then
        error("Fidelity: Kontoauszug ohne Kennung in der Serverantwort.")
      end
      if type(document.periodStartDate) ~= "number" or type(document.periodEndDate) ~= "number" then
        error("Fidelity: Kontoauszug ohne Zeitraum in der Serverantwort.")
      end
      if not knownSet[document.id] then
        local startText = os.date("%Y-%m-%d", document.periodStartDate)
        local endText = os.date("%Y-%m-%d", document.periodEndDate)
        statements[#statements + 1] = {
          name = "Kontoauszug " .. startText .. " bis " .. endText,
          identifier = document.id,
          creationDate = document.periodEndDate,
          filename = string.format("Fidelity_%s_%s_%s.pdf",
            string.sub(accountInfo.accountNumber, -4), startText, endText),
          pdf = downloadStatement(document, accountInfo)
        }
      end
    end
  end
  return statements
end

-- Kontotyp und Untertyp kommen von GetContext. Felder aus dem Konto-Objekt von MoneyMoney
-- sind nicht garantiert vorhanden (nur accountNumber und name sind Standardfelder).
local function resolveAccountInfo(account, person)
  local asset = findAsset(person, account.accountNumber)
  if type(asset.acctType) ~= "string" or type(asset.acctSubType) ~= "string" then
    error("Fidelity: Kontotyp fehlt in GetContext.")
  end
  return {
    name = account.name,
    accountNumber = account.accountNumber,
    accountType = asset.acctType,
    accountSubType = asset.acctSubType
  }, asset
end

function RefreshAccount(account, since)
  if not account or not account.accountNumber then
    error("Fidelity: Kontoabruf ohne Kontonummer nicht möglich.")
  end

  MM.printStatus("Refreshing account: " .. account.name)
  local nowTimestamp = os.time()

  local person = fetchContext()
  local accountInfo, asset = resolveAccountInfo(account, person)
  local balance = accountTotal(asset)
  local securities = buildPositions(fetchPositions(accountInfo, person.id), accountInfo.accountNumber)
  -- Umsätze sind Zusatzdaten: Ein Fehler darf Saldo und Positionen nicht verwerfen.
  -- Schlägt der Abruf fehl, fehlt das Feld "transactions" in der Rückgabe.
  local transactionsOk, transactionsResult = pcall(fetchTransactions, accountInfo, since, nowTimestamp)
  local transactions = nil
  if transactionsOk then
    transactions = transactionsResult
  else
    MM.printStatus("Fidelity: Umsätze nicht abgerufen: " .. tostring(transactionsResult))
  end

  return {
    balance = balance,
    securities = securities,
    transactions = transactions
  }
end

-- MoneyMoney ruft diese Funktion für die Kontoauszüge auf. Ein Fehler wird als Text zurückgegeben,
-- damit MoneyMoney ihn anzeigt; bereits geladene Auszüge werden dann nicht übergeben.
function FetchStatements(accounts, knownIdentifiers)
  local knownSet = {}
  if type(knownIdentifiers) == "table" then
    for key, value in pairs(knownIdentifiers) do
      if type(key) == "number" and type(value) == "string" then
        knownSet[value] = true
      elseif type(key) == "string" then
        knownSet[key] = true
      end
    end
  end

  local ok, result = pcall(function()
    local person = fetchContext()
    local statements = {}
    for _, account in ipairs(accounts or {}) do
      if not account or not account.accountNumber then
        error("Fidelity: Kontoauszug ohne Kontonummer nicht möglich.")
      end
      local accountInfo = resolveAccountInfo(account, person)
      for _, statement in ipairs(fetchNewStatements(accountInfo, knownSet)) do
        statements[#statements + 1] = statement
      end
    end
    return { statements = statements }
  end)

  if not ok then
    return tostring(result)
  end
  return result
end

function EndSession()
  -- If we keep a persisted connection in LocalStorage, avoid logging out,
  -- otherwise we would invalidate the session cookie jar.
  if session.cookies and session.cookies ~= "" and not session.persistedConnection then
    pcall(function()
      connection:request("GET", CONSTANTS.logoutUrl, nil, nil, { ["Cookie"] = session.cookies })
    end)
  end
  MM.printStatus("Logged out")
end

