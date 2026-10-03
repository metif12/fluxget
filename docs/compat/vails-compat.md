# vails compatibility report

Generated 2026-10-03 13:27:31 +03:30 by `scripts/sync-vails.ps1`.

| | |
|---|---|
| locked (vails.lock) | `ea96ecc199dbad980d3c2625eb218cda76b33be8` |
| checked out | `ea96ecc199dbad980d3c2625eb218cda76b33be8` |
| origin/main | `e4e99ad918f8d7b0fb426675597242580d77098f` |
| vails commit date | 2026-09-27T16:11:11+03:30 |

## Contract symbols (34 checked)

All contract symbols are present in the checked-out tree.

## Checked-out tree vs locked: 0 added, 0 removed

No change in the `pub` surface between the locked revision and the checked-out tree.

## origin/main vs locked: 218 added, 13 removed

What the newest upstream revision does to the surface. This is the comparison to read
when a run rolled back, because the checked-out tree is then the locked revision and
the section above is empty by construction.

### Removed or renamed upstream

- `services/notification.v:pub fn install_notification(mut router bridge.Router, ctx webview.Ctx) ! {`
- `services/notification.v:pub fn notification_backend(ctx webview.Ctx) Backend {`
- `services/notification.v:pub fn notify(ctx webview.Ctx, opts NotificationOptions) ! {`
- `state/store.v:pub fn (mut s Store) remove(key string) {`
- `state/store.v:pub fn (mut s Store) set(key string, val_json string) ! {`
- `state/store.v:pub fn (mut s Store) set_string(key string, val string) ! {`
- `state/store.v:pub fn (s Store) get(key string) !string {`
- `state/store.v:pub fn (s Store) get_string(key string) !string {`
- `state/store.v:pub fn (s Store) has(key string) bool {`
- `state/store.v:pub fn (s Store) keys() []string {`
- `state/store.v:pub fn (s Store) len() int {`
- `state/store.v:pub fn new_store() Store {`
- `state/store.v:pub struct Store {`

### Added upstream

- `buildinfo/buildinfo.v:pub const dev_version = 'dev'`
- `buildinfo/buildinfo.v:pub const framework_version = '0.4.0'`
- `buildinfo/buildinfo.v:pub const help = '--version <semver>   stamp the build (-d ' + ident +`
- `buildinfo/buildinfo.v:pub const ident = 'vails_version'`
- `buildinfo/buildinfo.v:pub fn describe() string {`
- `buildinfo/buildinfo.v:pub fn is_release() bool {`
- `buildinfo/buildinfo.v:pub fn is_release_version(v string) bool {`
- `buildinfo/buildinfo.v:pub fn v_mod_version(text string) ?string {`
- `buildinfo/buildinfo.v:pub fn validate_version(v string) !string {`
- `buildinfo/buildinfo.v:pub fn version() string {`
- `buildinfo/buildinfo.v:pub fn version_drift(v_mod_text string) string {`
- `buildplan/buildplan.v:pub const side_by_side_dlls = [`
- `buildplan/buildplan.v:pub const ucrt64_bin = 'C:/msys64/ucrt64/bin'`
- `buildplan/buildplan.v:pub fn (r Recipe) command(root string) string {`
- `buildplan/buildplan.v:pub fn (r Recipe) dll_targets() []string {`
- `buildplan/buildplan.v:pub fn (r Recipe) has_flag(flag string) bool {`
- `buildplan/buildplan.v:pub fn app_flags(target Target) []string {`
- `buildplan/buildplan.v:pub fn cli_flags(target Target) []string {`
- `buildplan/buildplan.v:pub fn missing_dlls(dir string) []string {`
- `buildplan/buildplan.v:pub fn needs_gc_none(target Target) bool {`
- `buildplan/buildplan.v:pub fn recipe(target Target, name string, windows_dll_side_by_side bool, version string) Recipe {`
- `buildplan/buildplan.v:pub fn stage_side_by_side(target Target, windows_dll_side_by_side bool) (bool, string, []string) {`
- `buildplan/buildplan.v:pub mut:`
- `buildplan/buildplan.v:pub struct Recipe {`
- `buildplan/toolchain.v:pub const default_toolchain_root = 'C:/msys64/ucrt64'`
- `buildplan/toolchain.v:pub const toolchain_env = 'VAILS_TOOLCHAIN'`
- `buildplan/toolchain.v:pub fn (tc &Toolchain) is_complete() bool {`
- `buildplan/toolchain.v:pub fn (tc &Toolchain) summary() string {`
- `buildplan/toolchain.v:pub fn cc_supported(cc string, needs_webview bool) ! {`
- `buildplan/toolchain.v:pub fn normalize_root(root string) string {`
- `buildplan/toolchain.v:pub fn resolve_toolchain() Toolchain {`
- `buildplan/toolchain.v:pub fn resolve_toolchain_from(env_root string) Toolchain {`
- `buildplan/toolchain.v:pub fn webview_links(imports_webview bool) bool {`
- `buildplan/toolchain.v:pub struct Toolchain {`
- `config/config.v:pub fn default_identifier(app_name string) string {`
- `config/config.v:pub fn validate_identifier(id string) ! {`
- `deps/deps.v:pub const lock_path = 'vails.lock'`
- `deps/deps.v:pub fn (s Set) encode() string {`
- `deps/deps.v:pub fn (s Set) get(name string) ?Dependency {`
- `deps/deps.v:pub fn (s Set) is_empty() bool {`
- `deps/deps.v:pub fn (s Set) names() []string {`
- `deps/deps.v:pub fn (s Set) summary() string {`
- `deps/deps.v:pub fn (s Set) to_v_mod_dependencies() string {`
- `deps/deps.v:pub fn decode_lock(text string) !Set {`
- `deps/deps.v:pub fn empty_set() Set {`
- `deps/deps.v:pub fn encode_lock(resolved []Dependency) string {`
- `deps/deps.v:pub fn is_exact_requirement(version string) bool {`
- `deps/deps.v:pub fn parse(text string) !Set {`
- `deps/deps.v:pub fn parse_report(text string) string {`
- `deps/deps.v:pub fn validate(items []Dependency) !Set {`
- `deps/deps.v:pub fn validate_dependency(d Dependency) ! {`
- `deps/deps.v:pub mut:`
- `deps/deps.v:pub struct Dependency {`
- `deps/deps.v:pub struct Set {`
- `examples/multiwindow/main.v:pub mut:`
- `examples/multiwindow/main.v:pub mut:`
- `services/dialog.v:pub const button_cancel = 'cancel'`
- `services/dialog.v:pub const button_no = 'no'`
- `services/dialog.v:pub const button_none = 'none'`
- `services/dialog.v:pub const button_ok = 'ok'`
- `services/dialog.v:pub const button_yes = 'yes'`
- `services/dialog.v:pub fn gtk_button_name(rc int) ?string {`
- `services/dialog.v:pub fn gtk_chooser_accepted(rc int) bool {`
- `services/dialog.v:pub fn gtk_message_result(rc int) Result {`
- `services/drop.v:pub const event_drop_files = 'drop:files'`
- `services/drop.v:pub fn (s &DropState) is_enabled() bool {`
- `services/drop.v:pub fn decide_drop(e webview.HostEvent, valid int) DropAction {`
- `services/drop.v:pub fn disable_drop(mut st &DropState) ! {`
- `services/drop.v:pub fn drop_backend(mut st &DropState) Backend {`
- `services/drop.v:pub fn drop_files_data(paths []string) string {`
- `services/drop.v:pub fn drop_manifest() Service {`
- `services/drop.v:pub fn drop_support() ServiceStatus {`
- `services/drop.v:pub fn enable_drop(mut st &DropState) ! {`
- `services/drop.v:pub fn install_drop(mut router bridge.Router, ctx webview.Ctx) !&DropState {`
- `services/drop.v:pub fn is_drop_message(e webview.HostEvent) bool {`
- `services/drop.v:pub fn validate_dropped_paths(paths []string) []string {`
- `services/drop.v:pub struct DropState {`
- `services/drop_test.v:pub mut:`
- `services/menu.v:pub const event_menu_canceled = 'menu:canceled'`
- `services/menu.v:pub const event_menu_clicked = 'menu:clicked'`
- `services/menu.v:pub const wm_command = u32(0x0111)`
- `services/menu.v:pub fn bar_click(e webview.HostEvent, ids []string) ?string {`
- `services/menu.v:pub fn canceled_data() string {`
- `services/menu.v:pub fn close(mut st &MenuState) ! {`
- `services/menu.v:pub fn emit_menu_clicked(ctx webview.Ctx, id string) ! {`
- `services/menu.v:pub fn flatten_items(items []MenuItem) []string {`
- `services/menu.v:pub fn install_menu(mut router bridge.Router, ctx webview.Ctx) ! {`
- `services/menu.v:pub fn is_valid_id(id string) bool {`
- `services/menu.v:pub fn is_valid_label(label string) bool {`
- `services/menu.v:pub fn menu_backend(ctx webview.Ctx) Backend {`
- `services/menu.v:pub fn menu_clicked_data(id string) string {`
- `services/menu.v:pub fn menu_manifest() Service {`
- `services/menu.v:pub fn menu_support() ServiceStatus {`
- `services/menu.v:pub fn parse_popup(params string) ![]MenuItem {`
- `services/menu.v:pub fn popup(mut st &MenuState, items []MenuItem) ! {`
- `services/menu.v:pub fn set_menu(mut st &MenuState, items []MenuItem) ! {`
- `services/menu.v:pub fn validate_items(items []MenuItem) ! {`
- `services/menu.v:pub mut:`
- `services/menu.v:pub mut:`
- `services/menu.v:pub mut:`
- `services/menu.v:pub struct MenuItem {`
- `services/menu.v:pub struct MenuPopup {`
- `services/menu.v:pub struct MenuState {`
- `services/notification.v:pub const backend_toast = 'toast'`
- `services/notification.v:pub fn escape_xml(s string) string {`
- `services/notification.v:pub fn install_notification(mut router bridge.Router, ctx webview.Ctx, id AppIdentity) ! {`
- `services/notification.v:pub fn notification_backend(ctx webview.Ctx, id AppIdentity) Backend {`
- `services/notification.v:pub fn notify(ctx webview.Ctx, id AppIdentity, opts NotificationOptions) !string {`
- `services/notification.v:pub fn toast_duration(timeout_ms int) string {`
- `services/notification.v:pub fn toast_xml(opts NotificationOptions) string {`
- `services/notification.v:pub struct AppIdentity {`
- `services/notification_windows.c.v:pub fn toast_available() bool {`
- `services/tray.v:pub const button_left = 'left'`
- `services/tray.v:pub const button_right = 'right'`
- `services/tray.v:pub const event_tray_clicked = 'tray:clicked'`
- `services/tray.v:pub fn (s &TrayState) has_menu() bool {`
- `services/tray.v:pub fn (s &TrayState) is_installed() bool {`
- `services/tray.v:pub fn button_lparam(button string) i64 {`
- `services/tray.v:pub fn classify_click(lparam i64) ?string {`
- `services/tray.v:pub fn decide(e webview.HostEvent, has_menu bool) TrayAction {`
- `services/tray.v:pub fn destroy_tray(mut st &TrayState) ! {`
- `services/tray.v:pub fn install_tray(mut router bridge.Router, ctx webview.Ctx) !&TrayState {`
- `services/tray.v:pub fn is_button(name string) bool {`
- `services/tray.v:pub fn parse_tray_options(params string) !TrayOptions {`
- `services/tray.v:pub fn set_tray(mut st &TrayState, opts TrayOptions) ! {`
- `services/tray.v:pub fn set_tray_menu(mut st &TrayState, items []MenuItem) ! {`
- `services/tray.v:pub fn simulate_click(st &TrayState, button string) ! {`
- `services/tray.v:pub fn tray_backend(mut st &TrayState) Backend {`
- `services/tray.v:pub fn tray_click(e webview.HostEvent, has_menu bool) ?TrayClick {`
- `services/tray.v:pub fn tray_clicked_data(c TrayClick) string {`
- `services/tray.v:pub fn tray_manifest() Service {`
- `services/tray.v:pub fn tray_menu_click(e webview.HostEvent, has_menu bool) bool {`
- `services/tray.v:pub fn tray_support() ServiceStatus {`
- `services/tray.v:pub fn validate_tray_options(opts TrayOptions) ! {`
- `services/tray.v:pub mut:`
- `services/tray.v:pub mut:`
- `services/tray.v:pub struct TrayClick {`
- `services/tray.v:pub struct TrayOptions {`
- `services/tray.v:pub struct TrayState {`
- `sqlreg/sqlreg.v:pub fn (q Query) bind(params map[string]string) ![]string {`
- `sqlreg/sqlreg.v:pub fn (q Query) is_write() bool {`
- `sqlreg/sqlreg.v:pub fn (q Query) mutability() string {`
- `sqlreg/sqlreg.v:pub fn (r QueryRegistry) get(name string) ?Query {`
- `sqlreg/sqlreg.v:pub fn (r QueryRegistry) names() []string {`
- `sqlreg/sqlreg.v:pub fn (r QueryRegistry) resolve(name string) !Query {`
- `sqlreg/sqlreg.v:pub fn (r QueryRegistry) resolve_read(name string) !Query {`
- `sqlreg/sqlreg.v:pub fn (r QueryRegistry) summary() string {`
- `sqlreg/sqlreg.v:pub fn bind_ok(q Query, params map[string]string) bool {`
- `sqlreg/sqlreg.v:pub fn bind_report(q Query, params map[string]string) string {`
- `sqlreg/sqlreg.v:pub fn new_registry(queries []Query) !QueryRegistry {`
- `sqlreg/sqlreg.v:pub fn validate_name(name string) ! {`
- `sqlreg/sqlreg.v:pub fn validate_statement(text string) ! {`
- `sqlreg/sqlreg.v:pub struct Query {`
- `sqlreg/sqlreg.v:pub struct QueryRegistry {`
- `state/appstate.v:pub fn (mut s AppState) remove(key string) {`
- `state/appstate.v:pub fn (mut s AppState) set(key string, val_json string) ! {`
- `state/appstate.v:pub fn (mut s AppState) set_string(key string, val string) ! {`
- `state/appstate.v:pub fn (s AppState) get(key string) !string {`
- `state/appstate.v:pub fn (s AppState) get_string(key string) !string {`
- `state/appstate.v:pub fn (s AppState) has(key string) bool {`
- `state/appstate.v:pub fn (s AppState) keys() []string {`
- `state/appstate.v:pub fn (s AppState) len() int {`
- `state/appstate.v:pub fn new_appstate() AppState {`
- `state/appstate.v:pub struct AppState {`
- `webview/ctx.v:pub fn (c Ctx) can_close() bool {`
- `webview/ctx.v:pub fn (c Ctx) close() ! {`
- `webview/ctx.v:pub fn (c Ctx) has_main() bool {`
- `webview/ctx.v:pub fn (c Ctx) has_toplevel() bool {`
- `webview/ctx.v:pub type CloseFn = fn ()`
- `webview/host.v:pub const host_message = u32(0x8001)`
- `webview/host.v:pub const wakeup_message = u32(0x8002)`
- `webview/host.v:pub fn (h &HostCtx) has_handler() bool {`
- `webview/host.v:pub fn (h &HostCtx) is_active() bool {`
- `webview/host.v:pub fn attach(ctx Ctx, on_event HostHandler) !&HostCtx {`
- `webview/host.v:pub fn detach(mut host &HostCtx) {`
- `webview/host.v:pub fn post_message(ctx Ctx, msg u32, wparam u64, lparam i64) ! {`
- `webview/host.v:pub mut:`
- `webview/host.v:pub struct HostCtx {`
- `webview/host.v:pub struct HostEvent {`
- `webview/host.v:pub type HostHandler = fn (e HostEvent) !bool`
- `webview/jobs.v:pub fn (mut mt MainThread) destroy() {`
- `webview/jobs.v:pub fn (mut mt MainThread) install_wakeup(ctx Ctx) ! {`
- `webview/jobs.v:pub fn (mut q JobQueue) destroy() {`
- `webview/jobs.v:pub fn (mut q JobQueue) drain() int {`
- `webview/jobs.v:pub fn (mut q JobQueue) push(job Job) {`
- `webview/jobs.v:pub fn (mut q JobQueue) run_batch(batch []Job) int {`
- `webview/jobs.v:pub fn (mut q JobQueue) take() []Job {`
- `webview/jobs.v:pub fn new_main_thread() &MainThread {`
- `webview/jobs.v:pub fn new_queue() JobQueue {`
- `webview/jobs.v:pub fn post_to_main(ctx Ctx, job Job) ! {`
- `webview/jobs.v:pub mut:`
- `webview/jobs.v:pub mut:`
- `webview/jobs.v:pub struct JobQueue {`
- `webview/jobs.v:pub struct MainThread {`
- `webview/jobs.v:pub type Job = fn ()`
- `webview/webview.v:pub fn check_windows(cfgs []Config) ! {`
- `webview/webview.v:pub fn run_many(cfgs []Config) ! {`
- `webview/window.v:pub fn (mut r WindowRegistry) add(w &Window) ! {`
- `webview/window.v:pub fn (mut r WindowRegistry) remove(label string) &Window {`
- `webview/window.v:pub fn (r &WindowRegistry) count() int {`
- `webview/window.v:pub fn (r &WindowRegistry) emit_all(event string, data string) ! {`
- `webview/window.v:pub fn (r &WindowRegistry) emit_to(label string, event string, data string) ! {`
- `webview/window.v:pub fn (r &WindowRegistry) find(label string) &Window {`
- `webview/window.v:pub fn (r &WindowRegistry) get(label string) !&Window {`
- `webview/window.v:pub fn (r &WindowRegistry) has(label string) bool {`
- `webview/window.v:pub fn (r &WindowRegistry) labels() []string {`
- `webview/window.v:pub fn (r &WindowRegistry) open_labels() []string {`
- `webview/window.v:pub fn (r &WindowRegistry) stop_all() ! {`
- `webview/window.v:pub fn (w &Window) can_emit() bool {`
- `webview/window.v:pub fn (w &Window) is_open() bool {`
- `webview/window.v:pub fn label_js(base string, label string) string {`
- `webview/window.v:pub fn new_registry() &WindowRegistry {`
- `webview/window.v:pub fn new_window(label string) &Window {`
- `webview/window.v:pub fn state_name(s WindowState) string {`
- `webview/window.v:pub mut:`
- `webview/window.v:pub mut:`
- `webview/window.v:pub struct Window {`
- `webview/window.v:pub struct WindowRegistry {`

## Fluxget commits to vails

Listed in the vails plan: `clipboard` (native half), `menu`, `tray`, `opener`,
`window-state`, then S2 `single-instance`. Each already has a `// COMPAT(...)` marker in
the Fluxget source; the ownership table lives in README.md under "Feature ownership".

Withdrawn upstream before Fluxget adopted them, so there is nothing to switch to and the
capability is ours to build: `notification` (`services/notification.v`) and the `store`
service (`state/store.v`). Both were in the plan and both are gone as of the revision
named in the `origin/main` section above.

