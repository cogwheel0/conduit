(function () {
  "use strict";
  // Conduit push has no dashboard page: its tab is hidden and Conduit manages it
  // through /api/plugins/conduit/. This placeholder only registers a component
  // so the dashboard does not report the plugin as failing to load.
  var SDK = window.__HERMES_PLUGIN_SDK__;
  if (!SDK || !window.__HERMES_PLUGINS__) return;
  var React = SDK.React;
  function ConduitPush() {
    return React.createElement(
      "p",
      null,
      "Conduit push notifications are managed from the Conduit app."
    );
  }
  window.__HERMES_PLUGINS__.register("conduit", ConduitPush);
})();
