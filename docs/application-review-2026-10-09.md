# FruityVens application review — October 9, 2026

## Scope and current status

This review covers the Flutter application, SQLite persistence, Firebase client integration, account and worker workflows, analytics, reports, forecasting tools, and ESP32-CAM integration. Findings come from source inspection, the existing automated checks, and targeted local reproductions. The audit did not modify production records or Firebase data.

Before the current changes, `flutter analyze` completed cleanly and all 24 existing tests passed. A debug APK was built and launched on the connected physical Android phone. These checks establish that the application builds and its covered workflows run; they do not establish that cloud authorization, synchronization between phones, or the physical camera/scale workflow is correct.

Firebase rules were not present in the repository and deployed rules were not inspected. Camera/scale hardware and live cross-device Firebase flows were not tested end to end. The serious findings below remain unresolved unless specifically identified as current work. Function names are used because source line numbers are changing during implementation.

### Changes implemented after the initial review

- An on-device forecast exposed a chart list-type error when appending the grouped Other series. Forecast chart collections now explicitly use numeric list types. A regression test generates nine fruit forecasts, renders the chart, and checks that Other preserves daily totals. The phone successfully displayed predictions for 1,389 completed transactions over 115 selling days across 20 fruits after the fix.

- Demand forecasting was unavailable because the local Python service was stopped and USB port forwarding was absent. The service now runs independently of the command session, and port 8787 is forwarded from the phone. A POST using the verified phone snapshot returned 20 valid seven-day fruit predictions from GradientBoostingRegressor. Unreachable-service errors now identify the demand service rather than directing users to Firebase AI setup.

- Analytics and Forecasting now omit generated-data banners and wording at the user's request. Stored provenance, History labels, and PDF labels remain. Best seller is the fruit with the greatest completed-sale revenue in the selected period; equal revenues are ordered alphabetically.

- History now uses a responsive header that keeps its full title visible beside the action buttons. Analytics and PDF reports show completed sales counts per fruit for the selected date range; cancelled and removed records are excluded. Counts describe transactions, while kilograms remain separately labeled as weight sold.

- The Cagayan de Oro market-outlook card remains in Forecasting and now sits at the bottom inside “What to do next.”
- At the user's request, 1,249 generated sales were imported directly into normal SQLite sales history, preserving 139 existing records for a total of 1,388. Stable `sample_cdo_` IDs prevent duplicates. The one-time “Add July–October sales” button has been removed, and the records remain in History. They contribute to normal totals and use the existing Firebase sync path; remote delivery was not independently verified. Their generated origin remains explicit.
- Raw numeric transaction totals and weights are now retained for calculations, correcting the display-string parsing problems described below.
- Chart aggregation now retains smaller fruit categories in an `Other` group.
- PDF export now supports up to 200 pages and generated-data labels. The whole generated-dataset PDF export test passes.

Final source validation on October 10, 2026: `flutter analyze --no-pub` reports no issues, all 34 tests pass, and `flutter build apk --debug --no-pub` succeeds. The update is installed on the physical Android phone. The integration test verifies that normal History receives generated records, keeps existing sales, skips duplicate imports, exposes edit controls, and includes every fruit in analytics totals. The phone import completed through the normal History screen. A consistent SQLite snapshot verified 1,388 saved records: 139 existing records preserved and 1,249 unique generated records, with generated totals of 1,865.375 kg and PHP 170,338.24. `PRAGMA integrity_check` returned `ok`. The existing database was backed up locally before installation. Live cloud rule enforcement and multi-device conflict recovery remain unverified.

**Synthetic data is not evidence of actual vendor demand or forecasting accuracy.** The sample scenario is invented. Historical price anchors provide context, not observed 2026 selling prices or real Cagayan de Oro transactions. See [sample methodology](cdo_sample_sales.md).

## Implemented features and architecture

| Area | Implemented behavior | Main implementation |
| --- | --- | --- |
| Application and navigation | Owner, Worker, and Guest flows; dashboard, inventory, transaction history, analytics, reports, forecasting, device controls | [`lib/main.dart`](../lib/main.dart) |
| Accounts | Email/password and Google sign-in; remembered local accounts; six-digit phone PIN and optional biometric unlock; shared worker account creation | `main.dart`, [`FirebaseSyncService`](../lib/services/firebase_sync_service.dart) |
| Local persistence | SQLite schema version 9; fruit catalog, sales, price history, accounts, settings, worker requests, market history, and an operation queue | [`AppDatabase`](../lib/data/app_database.dart) |
| Inventory and sales | Kilogram pricing, integer centavos, managed fruits, price changes, manually recorded sales, scale-log imports, sale correction/removal | `AppDatabase`, `main.dart` |
| Worker approval | Workers submit proposed sales and sale changes; owners approve or deny them; worker scale sales stay pending | `_submitWorkerRequest`, `_reviewWorkerRequest` |
| Cloud synchronization | Firebase Auth and Realtime Database; live inventory, transaction, and request subscriptions; periodic reconnect sync; device registration | `FirebaseSyncService`, `_startFirebaseLiveSync`, `_syncWhenInternetReturns` |
| Analytics and reports | Revenue, kilograms sold, rankings, history filters, PDF export, and forecast/recommendation presentation | `main.dart`, [`ReportExportService`](../lib/services/report_export_service.dart) |
| Vendor forecasting | Optional Python forecast backend; gradient-boosting or velocity fallback; lightweight PythonAnywhere implementation; Firebase AI/client fallbacks | [`AiAutomationClient`](../lib/services/ai_automation_client.dart), [`forecast_server.py`](../tool/forecast_server.py), [`forecast_server_pythonanywhere.py`](../tool/forecast_server_pythonanywhere.py) |
| Market context | Bundled PSA history, geographic fallbacks, price/supply indicators, rolling model comparisons, explicit observation/forecast periods | [`MarketOutlookService`](../lib/services/market_outlook_service.dart), [methodology](market_outlook_methodology.md) |
| Camera and detection | ESP32 snapshot/status controls, camera availability checks, Python YOLO tooling and optional detection proxy | [`CameraEyeService`](../lib/services/camera_eye_service.dart), [`ESP32_CAM_Stream.ino`](../ESP32_CAM_Stream/ESP32_CAM_Stream.ino), [`fruit_detection.py`](../tool/fruit_detection.py) |

The application is largely coordinated by one large stateful implementation in `main.dart`. UI rendering, authentication state, synchronization, business rules, calculations, and device operations are interleaved there. The service classes provide useful separation, but application-level tests cannot easily substitute a Firebase service or exercise independent state transitions. `AppDatabase.inMemory` is a separate map-based implementation, not an actual in-memory SQLite database for the methods exercised by the widget tests.

## Highest-priority unresolved findings

### 1. Accounts share the same business data on a phone

**Impact:** privacy leakage and contamination of another owner's cloud records. **Confidence:** high.

`AppDatabase._database` always opens `fruityvens.sqlite`. `local_fruits`, `sales_transactions`, and `price_change_history` have no account/owner column. `_signOut` clears session variables but retains these tables and the in-memory transaction history. `getSalesSyncPayloads` returns every local sale, and `FirebaseSyncService.syncTransactions` writes those records under the currently authenticated UID.

Reproduction: owner A records sales, logs out, and owner B signs in on the same phone. B sees A's local history and can upload it into B's cloud account. Inventory and price history are also shared. Worker requests have an owner UID, but that does not isolate the other tables.

**Recommended correction:** namespace storage, cached state, and settings by the data owner's stable ID; require matching local/cloud identities before sync; migrate existing data deliberately. Add an account-switch test containing real inventory and sales.

### 2. Reusable account passwords are stored as plaintext

**Impact:** reading the app database exposes saved owner and worker credentials. **Confidence:** high.

`AppDatabase.saveAccount` writes the supplied password directly into `local_accounts.password`. The app reads that password for comparison and automatic cloud sign-in. `_createSharedWorkerAccount` also saves the worker password on the owner's device. The phone PIN uses a salted SHA-256 verifier, but the actual account passwords are still readable.

**Recommended correction:** use a suitable offline password verifier and platform-protected authentication storage; avoid retaining reusable Firebase passwords. Handle migration of existing plaintext entries. No password values are included in this report.

### 3. Cloud snapshots change local sale IDs and silently discard open edits

**Impact:** a user can see a success message even though an edit or removal did not happen. **Confidence:** high; SQLite behavior reproduced locally.

`AppDatabase.saveSaleFromCloud` inserts with `ConflictAlgorithm.replace` and omits the existing primary key. Replacing a row with the same `cloud_id` allocates a new local `id`. An open edit dialog retains the old `sale.id`. `updateSale` prefers that ID even when a cloud ID is supplied, then returns silently if zero rows match. `_showEditTransactionDialog` still reports success. `_updateTransactionStatus` has the same stale-ID exposure.

Reproduction: open a sale edit dialog, allow a cloud refresh or the 30-second synchronization cycle to complete, and save. A local SQLite reproduction using the project schema changed ID 1 to ID 2 after replacement; updating ID 1 then affected zero rows. The map-based test database preserves IDs and misses this behavior.

**Recommended correction:** update or upsert while preserving the primary key, address records by stable identity, and return an explicit update result to the UI.

### 4. Stale sales snapshots can overwrite newer corrections

**Impact:** lost corrections and removed sales reappearing, with incorrect reports and forecasts. **Confidence:** high for overwrite behavior; inter-device outcomes depend on timing.

`getSalesSyncPayloads` uploads all sales, including unchanged records, and marks rows synced before network success. `_syncWhenInternetReturns` pushes transactions before its explicit transaction fetch. Incoming snapshots in `_applyCloudTransactionsFromFirebase` blindly replace local rows without comparing versions or pending edits. A stale device can overwrite a newer remote record, while an incoming stale record can overwrite an unsent local correction.

The SQLite reproduction also showed an unsent `removed` status reverting to `sold` with `synced=1` after applying an older snapshot.

**Recommended correction:** send only pending changes, acknowledge them after confirmed writes, protect pending local edits during pulls, and define version/conflict rules. Test two-device edits, removal, reconnect, and network failure sequences.

### 5. Password reset leaves saved accounts on the old login path

**Impact:** the new valid password is rejected on the phone; the old password continues to unlock local data. **Confidence:** high.

`_signIn` checks a saved account's local password and returns on mismatch before attempting Firebase authentication. After a Firebase password reset, entering the new password therefore fails locally. The old password still opens the local dashboard, although subsequent cloud authentication may fail.

**Recommended correction:** allow authoritative online authentication to refresh the local verifier, and define how reset/revocation affects offline access. Test a reset after the account has already been saved locally.

### 6. Weight conversion in both Python forecast servers misreads small gram amounts

**Impact:** substantial errors in training data and forecast quantities. **Confidence:** high; helper behavior reproduced.

Both `_weight_kg` implementations apply a magnitude heuristic to `weightGrams` instead of always dividing that explicitly named field by 1,000. A value of 25 grams becomes 25 kg, whereas 51 grams becomes 0.051 kg. The current Flutter payload includes `weightKg`, which avoids this particular branch; gram-only requests and compatible imported records remain affected.

**Recommended correction:** use the field's declared unit, not a numeric threshold. Add boundary tests for 1, 25, 50, 51, 1,000, and 1,234 grams in both servers.

### 7. Forecast dates and training targets are misaligned

**Impact:** predictions can be labeled for the wrong day and treat old sales as recent. **Confidence:** high from code and captured feature values.

In `forecast_server.py`, `_training_frame` trains features for day t against sales on day t+1. `_predict_horizon` constructs features for a future date and labels the resulting prediction as that same future date. Training and inference therefore disagree about the target date. Future transaction-count and revenue features are also forced to zero. `_fill_missing_days` stops at the last historical transaction, while forecasting starts from the current UTC day. Missing days between those dates are not represented. In a captured-feature reproduction, a stale January 7 record forecasting in October could still yield `days_since_sale=1`. The lightweight backend also anchors its recent-history calculations to the last observed sale rather than filling the intervening calendar gap.

**Recommended correction:** define one business timezone and forecast origin, align feature and target dates, and fill or explicitly flag the gap up to that origin. Test stale history, midnight boundaries, consecutive horizons, and partial current days.

## Additional unresolved workflow and integration findings

| Finding | Evidence and effect | Recommended follow-up |
| --- | --- | --- |
| Offline inventory deletion lacks durable replay | `hideManagedFruit` marks a fruit unmanaged and queues removal; no implementation consumes `sync_queue`. Normal inventory sync sends only managed fruits. A same-price cloud record can restore `managed=true` because conflict checks compare only price/unit. Some Firebase SDK writes may survive offline periods, but the app's own retry path does not cover failures or missing authentication. | Replay durable tombstones and pending operations; test removal with absent authentication, failed writes, restart, and reconnect. |
| Offline-only accounts never automatically register in Firebase | `_createAccount` saves a local account after cloud creation fails and promises later synchronization. Reconnect only calls `signInWithEmail`, which cannot create a missing Firebase account. | Track pending registration separately and provide a recoverable conflict/authentication flow. |
| Approval applies stale sale payloads without conflict checks | `_applyApprovedWorkerRequest` applies requested/original fields without validating whether the owner has since corrected the sale. A status-only request can restore old weight/price values. | Compare the original revision; apply the intended field change or require conflict review. |
| Approval and sale publication are not atomic | `_reviewWorkerRequest` applies the sale locally, changes request status, then awaits request sync before loading/syncing transactions. Failure can leave a local change with stale UI and delayed sale publication. Buttons have no per-request busy guard. | Make review idempotent and track a recoverable state transition; disable repeated actions while processing. |
| Tiny positive weights can become zero grams | Sale dialogs accept a positive decimal such as 0.0001 kg; rounding yields zero grams and unit-price calculation divides by zero. A Dart reproduction confirmed that converting the resulting infinity with `round()` throws. | Validate rounded grams before division. Verify whether the current numeric-data work includes this fix. |
| Editing a cancelled sale can default it to Sold | The edit dialog derives its initial status from whether it is Removed and otherwise chooses Sold, losing the Cancelled state. | Preserve all supported statuses or explicitly require a status change. |
| Detection tooling is not connected to the application workflow | `AiAutomationClient.detectFruits`, detection data models, proxy `/detect`, and Python model tooling exist, but `main.dart` does not call the detection client. | Implement and test camera image acquisition → inference → recognized fruit → pricing/scale flow. Do not describe it as field-validated automatic detection yet. |
| Enhanced proxy forecasting is a placeholder | `tool/ai_proxy_enhanced.dart` handles `/forecast` by reading the body and returning a generic summary instead of performing a forecast. | Implement the endpoint or report that it is unavailable; avoid presenting a placeholder as analysis. |
| Camera health may accept HTTP 404 | `CameraEyeService` reachability logic accepts responses that do not establish a working camera endpoint. An unrelated HTTP server can be considered reachable. | Require the expected success status and camera response/image contract. |
| One malformed scale record can abort a batch | `ScaleLogService` parsing does not isolate a malformed record from the other valid records in a response. | Validate each item independently and surface rejected records without dropping the usable batch. |
| Scale acknowledgment can precede durable cloud publication | Scale import acknowledges imported records before the full cloud publication has completed. | Document the acknowledgment contract and verify restart/retry recovery from local storage before confirming delivery. |
| Firebase token can be sent to an HTTP fallback | `AiAutomationClient` includes localhost/private-network HTTP backend defaults and attaches the Firebase bearer token to requests. Plain HTTP does not protect that token on a network path. | Require HTTPS for nonlocal authenticated requests or explicitly isolate a development-only path without production tokens. |
| Actual Wi-Fi password is in the working firmware source | `ESP32_CAM_Stream/ESP32_CAM_Stream.ino`, `WIFI_PASSWORD`, currently contains a password literal. The reviewed committed version used a placeholder. | Move the value into ignored local configuration and avoid committing it. No credential value is reproduced here. |

The Firebase client configuration files are not equivalent to private service-account credentials. The absence of repository rules is an audit limitation, not proof that the deployed database is publicly accessible. Owner/worker permissions, profile/link changes, request approval rights, and scale-price access need verification against actual deployed rules or an emulator rules suite.

## Analytics, report, and forecast validity

### Numeric aggregation defects being corrected in current work

The original calculations reparsed formatted display text. An extracted Dart reproduction showed a formatted PHP 1,200 amount becoming PHP 1. Weight display rounding also altered data: 25 g became 0 kg, while 1,234 g became 1,200 g. This affected totals, rankings, reports, and downstream forecast inputs. The current change retains raw centavos and grams in transaction data; final validation must demonstrate exact totals and parity across screens and exports. Chart grouping is also being updated to include the otherwise omitted smaller fruits under `Other`.

### Remaining report issues

- `ReportExportService` clamps chart segment heights to a nonzero minimum, so a zero-value category can appear as a visible bar segment. Render zero values as zero and verify chart totals.
- The report forecast path uses today's ranking data rather than the forecast result, so an exported forecast may not correspond to the AI/model output shown in the app. Export the same dated forecast and identify its source.

### Remaining market-model caveats

`MarketOutlookService` models selected observations as indexed values. A seasonal lag of four observations is only equivalent to four quarters when the quarterly sequence has no missing periods. Inspection found gaps in eight selected quarterly series; one pear series had 21 observations and 18 missing quarters. The service should preserve the calendar grid or restrict methods that assume regular sampling.

The market-outlook feature has a useful separation between PSA price/production context and a vendor's own sales. Preserve that distinction. The bundled extract ends before the current device date; a forecast for the period after the last official observation is not automatically a forecast for the upcoming period today. Display data coverage, real selected geography, category fallback, and forecast period explicitly.

For personalized sales forecasts, sample volume, a fitted model, or a confidence label does not establish real forecasting accuracy. Demonstrate accuracy using real chronological holdouts and compare against simple baselines. Distinguish sales from unconstrained demand: stockouts, closed days, missing imports, and partial days can all produce low recorded sales without low demand. Avoid claims that the supplied YOLO checkpoint is accurate in the shop until tested on representative camera images; the available checkpoint and its five classes only demonstrate the presence of a model artifact.

## Generated dataset in normal history

The generated dataset was imported into normal sales history at the user's request; there is no separate sample mode. Its documented scenario contains 1,249 transactions across 101 dates, July 1–October 9, 2026, totaling 1,865.375 kg and PHP 170,338.24. The phone retains those records alongside 139 existing sales, for 1,388 total records. The one-time import button has been removed. The dataset uses generated transaction IDs, Manila timestamps, integer grams, and integer centavos. The generator and documentation identify historical anchors and invented assumptions. See [`tool/generate_cdo_sample_sales.py`](../tool/generate_cdo_sample_sales.py) and [sample data documentation](cdo_sample_sales.md).

The completed import preserved existing sales and skipped already-present `sample_cdo_` cloud IDs. Imported rows contribute to the ordinary dashboard, history, analytics, reports, and forecasts and can synchronize through the existing Firebase flow. Those totals may therefore combine existing sales and invented transactions. Preserve generated-data labels and the stable ID prefix in displays, exports, and synchronized records. Forecasts using this history must disclose the generated inputs; official PSA observations remain market context rather than sales. The button-removal update passed static analysis, all 32 tests, and the Android debug build; it is installed on the phone, whose database still contains 1,388 records (1,249 generated) and passes its integrity check.

## Testing gaps and suggested order of work

The existing tests cover several login/navigation, inventory, history, worker-request, market-outlook, and AI-client behaviors. They do not validate the full application simply because all pass.

1. Add real SQLite tests for inserts, cloud upserts, stable IDs, pending edits, and schema upgrades. Keep the test implementation aligned with the actual database.
2. Test owner A → owner B and owner → worker transitions with inventory and sales already present. Verify that neither local views nor outgoing cloud payloads contain another owner's records.
3. Exercise password reset, revoked credentials, offline creation, reconnect, and interrupted sign-out/sign-in. Ensure local and Firebase identities match before reads or writes.
4. Add a controllable Firebase adapter and emulator/rules tests for roles, request creation/review, multi-device stale writes, network failures, retries, and deletion tombstones.
5. Test sale approval failures and concurrent review without losing a correction or publishing contradictory request/sale states.
6. Add numeric boundaries for sub-gram input, small gram payloads, fractional kilograms, formatted currency, and exact chart/report totals. Verify `Other` aggregation and zero-value charts.
7. Add Python tests for unit conversion, forecast target alignment, missing days, timezones, partial-day history, and chronological forecast evaluation. Test regular and gapped market series.
8. Run device integration tests for camera identity/status, real snapshot inference, scale-log partial failures, duplicate imports, and acknowledgment/restart recovery.
9. Verify direct-import idempotency, preservation of existing sales, generated-data labels, exact totals, and normal sync payloads, then rerun analyzer/tests and build/launch the updated APK. The final validation result should be recorded after all current changes settle.

The most urgent work is account isolation, credential storage, stable sale identity, and synchronization correctness. Those changes protect the records on which analytics and forecasting depend.
