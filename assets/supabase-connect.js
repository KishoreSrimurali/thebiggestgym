// Shared one-time "connect your Supabase project" flow for the staff and
// member portals. Nothing here is hardcoded: until the gym owner pastes in
// their own project's URL and anon key (through the UI this renders), the
// portals show this screen instead of any demo content.
//
// Storage: localStorage, key "bg_supabase_config" -> {"url": "...", "key": "..."}
// This never touches the service_role key — only the public anon key, which
// is safe to ship in client-side code and is the one Supabase RLS policies
// are designed to be used with.
(function (global) {
  const STORAGE_KEY = "bg_supabase_config";

  function readConfig() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed.url === "string" && typeof parsed.key === "string" && parsed.url && parsed.key) {
        return parsed;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  function writeConfig(url, key) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ url: url.trim(), key: key.trim() }));
      return true;
    } catch (e) {
      return false;
    }
  }

  function clearConfig() {
    try { localStorage.removeItem(STORAGE_KEY); } catch (e) { /* ignore */ }
  }

  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "html") el.innerHTML = v;
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) {
      if (kid != null && kid !== false) el.append(kid.nodeType ? kid : String(kid));
    }
    return el;
  }

  // Renders the "connect your project" screen into `mountEl` and calls
  // `onConnected()` once a value has been saved. appName shows in the heading.
  function renderSetupScreen(mountEl, appName, onConnected) {
    const urlInput = h("input", { type: "url", placeholder: "https://abcd1234.supabase.co", autocomplete: "off", spellcheck: "false" });
    const keyInput = h("textarea", { placeholder: "eyJhbGciOi...", rows: "3", autocomplete: "off", spellcheck: "false" });
    const errorBox = h("p", { class: "small", style: "color:var(--red); display:none" });

    const save = () => {
      const url = urlInput.value.trim();
      const key = keyInput.value.trim();
      if (!/^https:\/\/.+\.supabase\.co\/?$/i.test(url)) {
        errorBox.textContent = "That doesn't look like a Supabase project URL — it should look like https://abcd1234.supabase.co";
        errorBox.style.display = "block";
        return;
      }
      if (key.length < 20) {
        errorBox.textContent = "That key looks too short — copy the full anon public key.";
        errorBox.style.display = "block";
        return;
      }
      writeConfig(url, key);
      onConnected();
    };

    mountEl.replaceChildren(
      h("div", { class: "setup-screen" },
        h("div", { class: "box card" },
          h("div", { class: "brand" }, "THE BIGGEST ", h("span", {}, "GYM")),
          h("h2", { style: "margin-top:4px" }, "Connect your Supabase project"),
          h("p", { class: "muted small", style: "margin-top:12px" },
            `This is ${appName}. It only shows real, live information — so before it can show anything, it needs to know which Supabase project holds the gym's data.`),
          h("p", { class: "muted small" },
            "If you haven't made one yet: go to ", h("a", { href: "https://supabase.com", target: "_blank", rel: "noopener" }, "supabase.com"),
            ", create a free project, run the migration files from backend/supabase/migrations in its SQL Editor, then open ",
            h("strong", {}, "Project Settings → API"), " and copy the two values below."),
          h("label", {}, "Project URL"), urlInput,
          h("label", {}, "Anon public key (never the service_role key)"), keyInput,
          errorBox,
          h("button", { class: "btn-primary", style: "margin-top:18px; width:100%", onclick: save }, "Connect"),
          h("p", { class: "muted small", style: "margin-top:16px" },
            "This is saved only in this browser, on this device. Nothing is sent anywhere else."))));
  }

  // Renders a small "disconnect" control that clears the saved config and reloads.
  function disconnectButton(label = "Disconnect this project") {
    return h("button", { class: "btn-ghost btn-small", onclick: () => { if (confirm("Forget the connected Supabase project on this device?")) { clearConfig(); location.reload(); } } }, label);
  }

  global.BGConnect = { readConfig, writeConfig, clearConfig, renderSetupScreen, disconnectButton, h };
})(window);
