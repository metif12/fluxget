# vails compatibility report

Generated 2026-09-27 15:30:51 +03:30 by `scripts/sync-vails.ps1`.

| | |
|---|---|
| locked (vails.lock) | `(none - first run)` |
| checked out | `7e11fe22ecce47a06bb2c720842a159d0638c5d4` |
| origin/main | `7e11fe22ecce47a06bb2c720842a159d0638c5d4` |
| vails commit date | 2026-09-27T13:27:24+03:30 |

## Contract symbols (34 checked)

All contract symbols are present in the checked-out tree.

## Public API surface: 203 added, 0 removed

### Added

- `HEAD:application/application.v:18:pub struct App {`
- `HEAD:application/application.v:30:pub fn new(opts AppOptions) App {`
- `HEAD:application/application.v:39:pub fn (mut a App) register_service(name string) ! {`
- `HEAD:application/application.v:46:pub fn (a App) has_service(name string) bool {`
- `HEAD:application/application.v:50:pub fn (a App) is_running() bool {`
- `HEAD:application/application.v:55:pub fn (mut a App) set_state(key string, val_json string) ! {`
- `HEAD:application/application.v:60:pub fn (a App) get_state(key string) !string {`
- `HEAD:application/application.v:65:pub fn (a App) has_state(key string) bool {`
- `HEAD:application/application.v:8:pub struct AppOptions {`
- `HEAD:application/application.v:9:pub mut:`
- `HEAD:assets/assets.v:21:pub fn (s Server) read(path string) !string {`
- `HEAD:assets/assets.v:34:pub fn (s Server) resolve_for(window_label string, path string, reg capabilities.Registry) !string {`
- `HEAD:assets/assets.v:81:pub fn content_type(path string) string {`
- `HEAD:assets/assets.v:9:pub struct Server {`
- `HEAD:assets/bundle.v:14:pub struct Bundle {`
- `HEAD:assets/bundle.v:24:pub fn (b Bundle) read(path string) !string {`
- `HEAD:assets/bundle.v:32:pub fn (b Bundle) resolve_for(window_label string, path string, reg capabilities.Registry) !string {`
- `HEAD:bridge/bridge.v:105:pub fn validate_empty(params string) !void {`
- `HEAD:bridge/bridge.v:116:pub fn validate_any(params string) !void {`
- `HEAD:bridge/bridge.v:126:pub fn (r Router) call_from(window_label string, id string, method string, params string, reg capabilities.Registry) Response {`
- `HEAD:bridge/bridge.v:134:pub fn (r Router) call_json(window_label string, id string, method string, params string, reg capabilities.Registry) Response {`
- `HEAD:bridge/bridge.v:146:pub fn (r Router) call(id string, method string, params string) Response {`
- `HEAD:bridge/bridge.v:168:pub fn (r Router) call_validated(id string, method string, params string) Response {`
- `HEAD:bridge/bridge.v:20:pub struct Request {`
- `HEAD:bridge/bridge.v:201:pub fn (r Router) notify(window_label string, event string, data string, reg capabilities.Registry) !void {`
- `HEAD:bridge/bridge.v:21:pub mut:`
- `HEAD:bridge/bridge.v:211:pub fn encode_request(id string, method string, params string) string {`
- `HEAD:bridge/bridge.v:221:pub fn decode_request(raw string) !Request {`
- `HEAD:bridge/bridge.v:225:pub fn encode_notify(event string, data string) string {`
- `HEAD:bridge/bridge.v:234:pub fn decode_notify(raw string) !Notify {`
- `HEAD:bridge/bridge.v:238:pub fn encode_response(res Response) string {`
- `HEAD:bridge/bridge.v:27:pub struct Response {`
- `HEAD:bridge/bridge.v:28:pub mut:`
- `HEAD:bridge/bridge.v:36:pub struct Notify {`
- `HEAD:bridge/bridge.v:37:pub mut:`
- `HEAD:bridge/bridge.v:42:pub type MethodHandler = fn (params string) !string`
- `HEAD:bridge/bridge.v:46:pub type ParamsValidator = fn (params string) !void`
- `HEAD:bridge/bridge.v:48:pub struct Router {`
- `HEAD:bridge/bridge.v:54:pub fn new_router() Router {`
- `HEAD:bridge/bridge.v:61:pub fn (mut r Router) register(name string, h MethodHandler) ! {`
- `HEAD:bridge/bridge.v:71:pub fn (mut r Router) register_validated(name string, validate ParamsValidator, h MethodHandler) ! {`
- `HEAD:bridge/bridge.v:82:pub fn err_unknown(method string) string {`
- `HEAD:bridge/bridge.v:86:pub fn err_forbidden(method string, window_label string) string {`
- `HEAD:bridge/bridge.v:90:pub fn err_bad_request(detail string) string {`
- `HEAD:bridge/bridge.v:94:pub fn err_bad_params(detail string) string {`
- `HEAD:bridge/bridge.v:98:pub fn err_bad_event(detail string) string {`
- `HEAD:bridge/channels.v:13:pub struct Channel {`
- `HEAD:bridge/channels.v:22:pub fn (c Channel) is_closed() bool {`
- `HEAD:bridge/channels.v:29:pub fn (c Channel) push_js(data string) !string {`
- `HEAD:bridge/channels.v:39:pub fn (mut c Channel) close_js() string {`
- `HEAD:bridge/channels.v:46:pub struct ChannelHub {`
- `HEAD:bridge/channels.v:52:pub fn new_hub() ChannelHub {`
- `HEAD:bridge/channels.v:59:pub fn (mut h ChannelHub) open(event string) !Channel {`
- `HEAD:bridge/transport.v:103:pub fn (r Router) handle_envelope_from(raw string, window_label string, reg capabilities.Registry) string {`
- `HEAD:bridge/transport.v:134:pub fn resolve_js(res Response) string {`
- `HEAD:bridge/transport.v:148:pub fn runtime_js() string {`
- `HEAD:bridge/transport.v:16:pub fn (r Router) handle_message(raw string) string {`
- `HEAD:bridge/transport.v:160:pub fn runtime_js_bound(binding string) string {`
- `HEAD:bridge/transport.v:33:pub fn (r Router) handle_message_from(raw string, window_label string, reg capabilities.Registry) string {`
- `HEAD:bridge/transport.v:46:pub struct NotifyAck {`
- `HEAD:bridge/transport.v:47:pub mut:`
- `HEAD:bridge/transport.v:52:pub fn encode_notify_ack_ok() string {`
- `HEAD:bridge/transport.v:60:pub fn encode_notify_ack_err(msg string) string {`
- `HEAD:bridge/transport.v:72:pub fn (r Router) handle_notify_from(raw string, window_label string, reg capabilities.Registry) string {`
- `HEAD:bridge/transport.v:86:pub struct Envelope {`
- `HEAD:bridge/transport.v:87:pub mut:`
- `HEAD:bridge/transport.v:95:pub fn decode_envelope(raw string) !Envelope {`
- `HEAD:capabilities/capabilities.v:12:pub struct Capability {`
- `HEAD:capabilities/capabilities.v:22:pub struct Registry {`
- `HEAD:capabilities/capabilities.v:28:pub fn new_registry() Registry {`
- `HEAD:capabilities/capabilities.v:34:pub fn (mut r Registry) grant(c Capability) {`
- `HEAD:capabilities/capabilities.v:39:pub fn (r Registry) is_allowed(window_label string, command string) bool {`
- `HEAD:capabilities/capabilities.v:45:pub fn (r Registry) is_allowed_on(window_label string, command string, target_os string) bool {`
- `HEAD:capabilities/capabilities.v:64:pub fn (r Registry) asset_roots_of(window_label string, target_os string) []string {`
- `HEAD:config/config.v:133:pub fn (c VailsConfig) window(label string) !WindowConfig {`
- `HEAD:config/config.v:144:pub fn (c VailsConfig) to_registry() capabilities.Registry {`
- `HEAD:config/config.v:15:pub struct WindowConfig {`
- `HEAD:config/config.v:159:pub fn (c VailsConfig) encode() string {`
- `HEAD:config/config.v:16:pub mut:`
- `HEAD:config/config.v:26:pub struct CapabilitySpec {`
- `HEAD:config/config.v:27:pub mut:`
- `HEAD:config/config.v:38:pub struct BundleConfig {`
- `HEAD:config/config.v:39:pub mut:`
- `HEAD:config/config.v:47:pub struct VailsConfig {`
- `HEAD:config/config.v:48:pub mut:`
- `HEAD:config/config.v:59:pub fn default_config(app_name string) VailsConfig {`
- `HEAD:config/config.v:77:pub fn load(path string) !VailsConfig {`
- `HEAD:config/config.v:86:pub fn load_text(text string) !VailsConfig {`
- `HEAD:config/config.v:96:pub fn (c VailsConfig) validate() ! {`
- `HEAD:dev/dev.v:117:pub fn (s DevServer) current_version() string {`
- `HEAD:dev/dev.v:124:pub fn (s DevServer) frontend_version() string {`
- `HEAD:dev/dev.v:152:pub fn status_for_err(err IError) http.Status {`
- `HEAD:dev/dev.v:162:pub fn inject_livereload(html string, port int) string {`
- `HEAD:dev/dev.v:177:pub fn livereload_snippet(port int) string {`
- `HEAD:dev/dev.v:22:pub const default_port = 8413`
- `HEAD:dev/dev.v:26:pub const version_path = '/__vails_dev_version'`
- `HEAD:dev/dev.v:30:pub struct DevServer {`
- `HEAD:dev/dev.v:44:pub struct ServeResult {`
- `HEAD:dev/dev.v:50:pub fn new_dev_server(root string, asset_root string, port int, reg capabilities.Registry, label string) DevServer {`
- `HEAD:dev/dev.v:62:pub fn (s DevServer) dev_url() string {`
- `HEAD:dev/dev.v:69:pub fn (s DevServer) resolve_request(raw_path string) !ServeResult {`
- `HEAD:dev/serve.v:36:pub fn (s DevServer) run() ! {`
- `HEAD:events/common.v:14:pub const common_battery = 'common:battery'`
- `HEAD:events/common.v:15:pub const common_network = 'common:network'`
- `HEAD:events/common.v:16:pub const common_theme = 'common:theme'`
- `HEAD:events/common.v:17:pub const common_low_memory = 'common:low-memory'`
- `HEAD:events/events.v:14:pub fn new_bus() Bus {`
- `HEAD:events/events.v:20:pub fn (mut b Bus) on(event string, h Handler) {`
- `HEAD:events/events.v:26:pub fn (b Bus) emit(event string, data string) int {`
- `HEAD:events/events.v:34:pub fn (b Bus) handler_count(event string) int {`
- `HEAD:events/events.v:5:pub type Handler = fn (data string)`
- `HEAD:events/events.v:9:pub struct Bus {`
- `HEAD:events/js.v:8:pub fn to_js(event string, data string) string {`
- `HEAD:generator/generator.v:16:pub fn generate_dts(namespace string, methods []MethodSpec) string {`
- `HEAD:generator/generator.v:7:pub struct MethodSpec {`
- `HEAD:jsesc/jsesc.v:8:pub fn escape(s string) string {`
- `HEAD:mobile/mobile.v:20:pub fn apply_geometry(width int, height int) ! {`
- `HEAD:mobile/mobile.v:9:pub fn is_mobile() bool {`
- `HEAD:services/catalog.v:16:pub fn manifests() []Service {`
- `HEAD:services/clipboard.v:20:pub fn clipboard_manifest() Service {`
- `HEAD:services/clipboard.v:47:pub fn read_text() !string {`
- `HEAD:services/clipboard.v:57:pub fn write_text(text string) ! {`
- `HEAD:services/clipboard.v:73:pub fn install_clipboard(mut router bridge.Router, _ctx webview.Ctx) ! {`
- `HEAD:services/dialog.v:106:pub fn (o Options) validate(want string) ! {`
- `HEAD:services/dialog.v:148:pub fn validate_filter(f Filter) ! {`
- `HEAD:services/dialog.v:177:pub fn is_button_set(s string) bool {`
- `HEAD:services/dialog.v:184:pub fn native_filter_string(filters []Filter) string {`
- `HEAD:services/dialog.v:204:pub fn encode_result(r Result) string {`
- `HEAD:services/dialog.v:213:pub fn parse_paths(buf string) []string {`
- `HEAD:services/dialog.v:224:pub fn dialog_manifest() Service {`
- `HEAD:services/dialog.v:27:pub const kind_open = 'open'`
- `HEAD:services/dialog.v:276:pub fn dialog_backend(ctx webview.Ctx) Backend {`
- `HEAD:services/dialog.v:28:pub const kind_save = 'save'`
- `HEAD:services/dialog.v:29:pub const kind_message = 'message'`
- `HEAD:services/dialog.v:303:pub fn install_dialog(mut router bridge.Router, ctx webview.Ctx) ! {`
- `HEAD:services/dialog.v:32:pub const buttons_ok = 'ok'`
- `HEAD:services/dialog.v:33:pub const buttons_ok_cancel = 'okcancel'`
- `HEAD:services/dialog.v:34:pub const buttons_yes_no_cancel = 'yesnocancel'`
- `HEAD:services/dialog.v:48:pub struct Filter {`
- `HEAD:services/dialog.v:49:pub mut:`
- `HEAD:services/dialog.v:57:pub struct Options {`
- `HEAD:services/dialog.v:58:pub mut:`
- `HEAD:services/dialog.v:72:pub struct Result {`
- `HEAD:services/dialog.v:73:pub mut:`
- `HEAD:services/dialog.v:83:pub fn parse_options(want string, params string) !Options {`
- `HEAD:services/dts.v:16:pub fn (s Service) specs() []generator.MethodSpec {`
- `HEAD:services/dts.v:34:pub fn dts(svcs []Service) string {`
- `HEAD:services/dts.v:61:pub fn snippets(svcs []Service) string {`
- `HEAD:services/dts.v:73:pub fn granted_commands(commands []string) []string {`
- `HEAD:services/install.v:24:pub type Handler = fn (params string) !string`
- `HEAD:services/install.v:26:pub type Backend = map[string]Handler`
- `HEAD:services/install.v:32:pub fn install(mut router bridge.Router, s Service, backend Backend) ! {`
- `HEAD:services/install.v:55:pub fn install_all(mut router bridge.Router, svcs []Service, backends map[string]Backend) ! {`
- `HEAD:services/manifest.v:107:pub fn (s Service) js_snippet() string {`
- `HEAD:services/manifest.v:122:pub fn find(name string) ?Service {`
- `HEAD:services/manifest.v:128:pub fn find_in(list []Service, name string) ?Service {`
- `HEAD:services/manifest.v:140:pub fn service_of(command string) ?Service {`
- `HEAD:services/manifest.v:145:pub fn service_in(list []Service, command string) ?Service {`
- `HEAD:services/manifest.v:15:pub struct Command {`
- `HEAD:services/manifest.v:162:pub fn lookup(command string) ?(Service, Command) {`
- `HEAD:services/manifest.v:167:pub fn lookup_in(list []Service, command string) ?(Service, Command) {`
- `HEAD:services/manifest.v:184:pub fn select_for(granted []string) ([]Service, []string) {`
- `HEAD:services/manifest.v:189:pub fn select_in(list []Service, granted []string) ([]Service, []string) {`
- `HEAD:services/manifest.v:33:pub const no_params = ''`
- `HEAD:services/manifest.v:36:pub struct Service {`
- `HEAD:services/manifest.v:51:pub fn (s Service) prefix() string {`
- `HEAD:services/manifest.v:56:pub fn (s Service) has_command(name string) bool {`
- `HEAD:services/manifest.v:62:pub fn (s Service) command_names() []string {`
- `HEAD:services/manifest.v:71:pub fn (s Service) command(name string) ?Command {`
- `HEAD:services/manifest.v:82:pub fn (s Service) own_command(name string) bool {`
- `HEAD:services/manifest.v:88:pub fn (c Command) short_name() string {`
- `HEAD:services/manifest.v:96:pub fn (c Command) matches(name string) bool {`
- `HEAD:services/os_info.v:22:pub struct Info {`
- `HEAD:services/os_info.v:23:pub mut:`
- `HEAD:services/os_info.v:50:pub fn os_info_manifest() Service {`
- `HEAD:services/os_info.v:79:pub fn collect() Info {`
- `HEAD:services/os_info.v:90:pub fn os_info_backend() Backend {`
- `HEAD:services/os_info.v:99:pub fn install_os_info(mut router bridge.Router) ! {`
- `HEAD:state/store.v:15:pub struct Store {`
- `HEAD:state/store.v:21:pub fn new_store() Store {`
- `HEAD:state/store.v:30:pub fn (mut s Store) set(key string, val_json string) ! {`
- `HEAD:state/store.v:38:pub fn (s Store) get(key string) !string {`
- `HEAD:state/store.v:43:pub fn (mut s Store) remove(key string) {`
- `HEAD:state/store.v:48:pub fn (s Store) has(key string) bool {`
- `HEAD:state/store.v:53:pub fn (s Store) len() int {`
- `HEAD:state/store.v:58:pub fn (s Store) keys() []string {`
- `HEAD:state/store.v:63:pub fn (mut s Store) set_string(key string, val string) ! {`
- `HEAD:state/store.v:68:pub fn (s Store) get_string(key string) !string {`
- `HEAD:webview/ctx.v:19:pub type EvalFn = fn (js string) !`
- `HEAD:webview/ctx.v:24:pub struct Ctx {`
- `HEAD:webview/ctx.v:25:pub mut:`
- `HEAD:webview/ctx.v:39:pub fn (c Ctx) emit(event string, data string) ! {`
- `HEAD:webview/ctx.v:47:pub fn (c Ctx) run_js(js string) ! {`
- `HEAD:webview/ctx.v:55:pub fn (c Ctx) has_parent() bool {`
- `HEAD:webview/ctx.v:60:pub fn (c Ctx) is_ready() bool {`
- `HEAD:webview/secure.v:16:pub fn default_csp() string {`
- `HEAD:webview/secure.v:21:pub fn csp_meta() string {`
- `HEAD:webview/secure.v:30:pub fn inject_csp(html string) string {`
- `HEAD:webview/webview.v:40:pub fn (cfg Config) document() string {`
- `HEAD:webview/webview.v:52:pub fn (cfg Config) validate() ! {`
- `HEAD:webview/webview.v:63:pub fn run(cfg Config) ! {`
- `HEAD:webview/webview.v:8:pub struct Config {`
- `HEAD:webview/webview.v:9:pub mut:`

## Fluxget commits to vails

Next in the vails plan: `notification`, `clipboard` (native half), `menu`, `tray`,
`opener`, `window-state`, then S2 `single-instance` and `store`. Each already has a
`// COMPAT(...)` marker in the Fluxget source; the ownership table lives in README.md
under "Feature ownership".

