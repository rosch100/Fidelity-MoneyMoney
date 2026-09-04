# Fidelity — MoneyMoney Extension
Plugin Homepage: https://github.com/rosch100/Fidelity-MoneyMoney
Bank/Portal: https://www.fidelity.com
Version: **0.92**
Status: Beta — Cookie-Import (Username/Passwort blockiert: Akamai + MFA)
Hub (gemeinsame Tools/Doku): https://github.com/rosch100/moneymoney-extensions
## Installation
Unsignierte Datei: [Fidelity.lua](https://raw.githubusercontent.com/rosch100/Fidelity-MoneyMoney/main/Fidelity.lua)
Datei nach `~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions` kopieren, oder im Klon `./link_ext.sh` ausführen.
Unsignierte Plugins: MoneyMoney-**Beta**, Signaturprüfung in den Erweiterungseinstellungen aus.
## Tests
`sh
python3 tests/test_conformance.py
luajit tests/test_fidelity_cookie_import.lua
luajit tests/test_fidelity_asset_allocation_fallback.lua

`
Aus dem Repo-Root ausführen.

