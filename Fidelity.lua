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
  graphqlApi = "https://digital.fidelity.com/ftgw/digital/picoserver/api/graphql",
  portfolioSummary = "https://digital.fidelity.com/ftgw/digital/portfolio/summary",
  portfolioGetContextApi = "https://digital.fidelity.com/ftgw/digital/portfolio/api/GetContext",
  assetAllocationApi = "https://digital.fidelity.com/ftgw/digital/performance-api/v1/asset-allocation",
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

local function getContextQuery()
  return {
    operationName = "GetContext",
    variables = {},
    query = [[query GetContext {
      getContext {
        person {
          assets {
            acctNum
            acctType
            acctSubType
            acctSubTypeDesc
            gainLossBalanceDetail {
              totalMarketVal
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
    }]]
  }
end

local function isAuthenticatedViaGraphql()
  if not session.cookies or session.cookies == "" then
    return false
  end

  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary,
    ["apollographql-client-version"] = "0.0.0"
  }

  local response, _ = connection:request(
    "POST",
    CONSTANTS.graphqlApi .. "?ref_at=portsum",
    JSON():set(getContextQuery()):json(),
    "application/json",
    headers
  )

  if not response or type(response) ~= "string" then
    return nil
  end

  local success, data = pcall(function() return JSON(response):dictionary() end)
  if not success or not data or not data.data or not data.data.getContext then
    return false
  end

  local person = data.data.getContext.person
  local assets = person and person.assets
  return type(assets) == "table" and #assets > 0
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
  local viaGraphql = isAuthenticatedViaGraphql()
  if viaGraphql == true then
    return true
  end

  MM.printStatus("Cookie-Validierung via GraphQL fehlgeschlagen; versuche GetContext...")
  local viaGetContext = isAuthenticatedViaPortfolioGetContext()
  if viaGetContext == true then
    return true
  end
  if viaGraphql == nil and viaGetContext == nil then
    return nil
  end
  return false
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

local function buildGraphqlPortfolio(data)
  local positionData = data.data.getPosition
  local priceLookup = {}
  for _, position in ipairs(positionData.topBottomPositions or {}) do
    local lastPrice = tonumber(position.lastPrice)
    if position.symbol and lastPrice then
      priceLookup[position.symbol] = lastPrice
    end
  end

  local accountDetails = positionData.position
    and positionData.position.acctDetails
    and positionData.position.acctDetails.acctDetail
  if type(accountDetails) ~= "table" then
    return nil
  end

  local securities = {}
  local totalBalance = 0
  for _, accountDetail in ipairs(accountDetails) do
    local positions = accountDetail.positionDetails
      and accountDetail.positionDetails.positionDetail
    if type(positions) ~= "table" then
      return nil
    end

    for _, position in ipairs(positions) do
      local symbol = position.symbol
      local quantity = tonumber(position.quantity)
      local marketValue = position.marketValDetail
        and tonumber(position.marketValDetail.marketVal)
      local totalGainLoss = position.marketValDetail
        and tonumber(position.marketValDetail.totalGainLoss)
      local purchasePrice = totalGainLoss and quantity and quantity > 0 and marketValue
        and (marketValue - totalGainLoss) / quantity
        or nil
      local security = buildSecurity({
        name = position.securityDescription,
        symbol = symbol,
        cusip = position.cusip,
        quantity = quantity,
        price = resolveSecurityPrice(
          symbol and priceLookup[symbol] or nil,
          quantity,
          marketValue),
        marketValue = marketValue,
        purchasePrice = purchasePrice
      })
      if not security then
        return nil
      end
      table.insert(securities, security)
      totalBalance = totalBalance + marketValue
    end
  end

  if #securities == 0 then
    return nil
  end
  return { balance = totalBalance, securities = securities }
end

local function buildRestPortfolio(data)
  local payload = data
  if type(data.assetAllocation) == "table" then
    payload = data.assetAllocation
  end

  local holdings = payload.holdingsDetails
  if not holdings and payload.aggregateStyleDetail then
    holdings = payload.aggregateStyleDetail.holdingDetails
  end

  local totalBalance = tonumber(payload.overallMarketValue)
  if totalBalance == nil and type(holdings) == "table" then
    totalBalance = 0
    for _, holding in ipairs(holdings) do
      local marketValue = tonumber(holding.marketValue)
      if marketValue == nil then
        error("Fidelity: Marktwert einer Position fehlt oder ist ungültig.")
      end
      totalBalance = totalBalance + marketValue
    end
  end
  if totalBalance == nil then
    error("Fidelity: Kontostand fehlt in der Serverantwort.")
  end
  if type(holdings) ~= "table" then
    error("Fidelity: Positionen fehlen in der Serverantwort oder haben ein ungültiges Format.")
  end

  local securities = {}
  for _, holding in ipairs(holdings) do
    local symbol = holding.symbol
    local quantity = tonumber(holding.quantity)
    local marketValue = tonumber(holding.marketValue)
    local security = buildSecurity({
      name = holding.longName or holding.name or symbol,
      symbol = symbol,
      cusip = holding.cusip,
      quantity = quantity,
      price = resolveSecurityPrice(holding.price, quantity, marketValue),
      marketValue = marketValue
    })
    if not security then
      error("Fidelity: Serverantwort enthält mindestens eine unvollständige Position.")
    end
    table.insert(securities, security)
  end

  return { balance = totalBalance, securities = securities }
end

function RefreshAccount(account, since)
  if not account or not account.accountNumber then
    error("Fidelity: Kontoabruf ohne Kontonummer nicht möglich.")
  end

  MM.printStatus("Refreshing account: " .. account.name)

  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary,
    ["apollographql-client-version"] = "0.0.0"
  }

  local function fetchGraphqlPositions()
    local positionsQuery = {
      operationName = "GetPositions",
      variables = {
        acctList = {
          {
            acctNum = account.accountNumber,
            acctType = account.accountType or "Brokerage",
            acctSubType = account.accountSubType or "Mutual Fund",
            preferenceDetail = false
          }
        },
        customerId = ""
      },
      query = [[query GetPositions($acctList: [PositionAccountInput], $customerId: String) {
        getPosition(acctList: $acctList, customerId: $customerId) {
          position {
            acctDetails {
              acctDetail {
                acctNum
                positionDetails {
                  positionDetail {
                    symbol
                    cusip
                    securityDescription
                    quantity
                    marketValDetail {
                      marketVal
                      totalGainLoss
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          topBottomPositions {
            symbol
            lastPrice
            __typename
          }
          __typename
        }
      }]]
    }

    local response, _, mimeType = connection:request(
      "POST",
      CONSTANTS.graphqlApi .. "?ref_at=portsum",
      JSON():set(positionsQuery):json(),
      "application/json",
      headers
    )
    -- GraphQL kann fehlschlagen (z.B. 404) und dabei kann `connection:getCookies()`
    -- ggf. das Cookie-Jar wieder auf einen weniger vollständigen Stand bringen
    -- (fehlende portsum_.csrf Cookies). Für den REST-Fallback ist dann
    -- die ursprüngliche `session.cookies` (aus Cookie-Import) entscheidend.
    local newCookies = connection:getCookies() or ""
    if newCookies ~= "" and extractCookieValue(newCookies, "portsum_.csrf") then
      -- Nur aktualisieren, wenn wirklich der kritische portsum_.csrf Wert dabei ist.
      -- Sonst kann es passieren, dass nach einem GraphQL-Fehlschlag nur Teil-Cookies
      -- im Jar landen und der REST-Fallback dann "ports=false" sieht.
      session.cookies = mergeCookies(session.cookies, newCookies)
    end
    if not response or type(response) ~= "string" then
      return nil
    end

    if response:find("<!doctype html", 1, false) or (mimeType and mimeType:find("html")) then
      return nil
    end

    local success, data = pcall(function() return JSON(response):dictionary() end)
    if not success or not data or not data.data or not data.data.getPosition then
      return nil
    end

    return data
  end

  local localData = fetchGraphqlPositions()
  if localData then
    local graphqlPortfolio = buildGraphqlPortfolio(localData)
    if graphqlPortfolio then
      return graphqlPortfolio
    end
  end

  -- REST-Fallback: asset-allocation liefert mindestens Marktwerte (Balance).
  local restHeadersBase = {
    -- HAR (digital.fidelity.com/ftgw/digital/portfolio/performance) verwendet eine "json, text/plain"-Accept-Matrix
    ["Accept"] = "application/json, text/plain, */*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    -- Für performance-api sind Referer/Context relevant.
    ["Referer"] = "https://digital.fidelity.com/ftgw/digital/portfolio/performance",
    -- In HAR ist bei vielen performance-api Calls zusätzlich ein IP-Override Header gesetzt.
    ["x-override-ip"] = "true",
    ["X-Requested-With"] = "XMLHttpRequest"
  }

  local body = {
    includeAggregate = true,
    includeHoldingsDetails = true,
    includeGranular = true,
    excludeEquityStyle = false,
    excludeBondStyle = false,
    accounts = {
      {
        accountNum = account.accountNumber,
        -- Fidelitys `asset-allocation` scheint diese Felder (zumindest im HAR) für die Anfrageform
        -- eng zu erwarten; deshalb konstant setzen und nur `accountNum` variieren.
        accountType = "Brokerage",
        accountSubType = "Mutual Fund"
      }
    }
  }

  local csrfPorts = extractCookieValue(session.cookies, "portsum_.csrf")
  local csrfPortsum = extractCookieValue(session.cookies, "PORTSUM_XSRF-TOKEN")

  local function isHtmlLogin(resp, mt)
    if not resp or type(resp) ~= "string" then
      return false
    end
    return resp:find("<!doctype html", 1, false)
      or (mt and mt:find("html"))
      or (resp:find("<html", 1, false) ~= nil)
  end

  local function fetchAssetAllocationWithCsrf(csrfToken)
    local restHeaders = {}
    for k, v in pairs(restHeadersBase) do
      restHeaders[k] = v
    end
    if csrfToken then
      -- Einige Fidelity-Endpunkte akzeptieren "x-csrf-token" statt "X-XSRF-TOKEN".
      restHeaders["x-csrf-token"] = csrfToken
    end

    local response, _, mimeType = connection:request(
      "POST",
      CONSTANTS.assetAllocationApi,
      JSON():set(body):json(),
      "application/json",
      restHeaders
    )
    local newCookies = connection:getCookies() or ""
    if newCookies ~= "" and extractCookieValue(newCookies, "portsum_.csrf") then
      session.cookies = mergeCookies(session.cookies, newCookies)
    end

    if not response or type(response) ~= "string" then
      return nil, mimeType
    end
    return response, mimeType
  end

  -- Deterministisch: bevorzugt PORTSUM_XSRF-TOKEN, sonst portsum_.csrf.
  local csrfTokenPreferred = csrfPortsum or csrfPorts
  local response, mimeType = fetchAssetAllocationWithCsrf(csrfTokenPreferred)

  if not response or type(response) ~= "string" then
    error("Fidelity: Keine Serverantwort beim Kontoabruf.")
  end

  if isHtmlLogin(response, mimeType) then
    error("Fidelity: performance-api Session ungültig (Login-Seite bekommen). Bitte Cookie Import mit frischen Cookies wiederholen (PORTSUM_XSRF-TOKEN / portsum_.csrf prüfen).")
  end

  local success, data = pcall(function() return JSON(response):dictionary() end)
  if not success or not data then
    error("Fidelity: Ungültige Serverantwort beim Kontoabruf.")
  end

  return buildRestPortfolio(data)
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

