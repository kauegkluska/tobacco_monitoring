// Inicialização: sessão, estrutura da página e navegação por hash (#/inicio, #/historico...).

import { startBuzzerWatch, stopBuzzerWatch } from "./buzzer.js";
import { api } from "./api.js";
import { clear, h, icon, toast } from "./dom.js";
import { renderAlerts } from "./pages/alerts.js";
import { renderAuth } from "./pages/auth.js";
import { renderDashboard } from "./pages/dashboard.js";
import { renderHistory } from "./pages/history.js";
import { renderProfile } from "./pages/profile.js";
import { renderUnits } from "./pages/units.js";
import { applyTheme, prefs } from "./store.js";

const ROUTES = [
  { path: "inicio", label: "Início", title: "Visão geral", icon: "dashboard", render: renderDashboard },
  { path: "historico", label: "Histórico", title: "Histórico de leituras", icon: "chart", render: renderHistory },
  { path: "alertas", label: "Alertas", title: "Central de alertas", icon: "bell", render: renderAlerts },
  { path: "estufas", label: "Estufas", title: "Estufas e dispositivos", icon: "warehouse", render: renderUnits },
  { path: "perfil", label: "Perfil", title: "Perfil e ajustes", icon: "person", render: renderProfile },
];
const BADGE_POLL_MS = 30_000;

const app = document.getElementById("app");
let current = null;
let shell = null;
let user = null;
let badgeTimer = null;

function parseHash() {
  const [path, queryString = ""] = window.location.hash.replace(/^#\/?/, "").split("?");
  return { route: ROUTES.find((route) => route.path === path) || null, query: new URLSearchParams(queryString) };
}

function navigate(hash) {
  if (window.location.hash === hash) renderRoute();
  else window.location.hash = hash;
}

function setAlertCount(count) {
  if (!shell) return;
  for (const badgeElement of shell.badges) {
    badgeElement.textContent = count > 99 ? "99+" : String(count);
    badgeElement.hidden = count === 0;
  }
  const alertLinks = shell.root.querySelectorAll('[data-route="alertas"]');
  alertLinks.forEach((link) => link.setAttribute("aria-label", count ? `Alertas (${count} ativos)` : "Alertas"));
}

async function refreshAlertCount() {
  clearTimeout(badgeTimer);
  try {
    const alerts = await api.get("/alerts/?active=true&limit=1000");
    setAlertCount(alerts.length);
  } catch (_) {
    // O indicador de conexão já mostra a falha.
  } finally {
    if (api.isAuthenticated) badgeTimer = setTimeout(refreshAlertCount, BADGE_POLL_MS);
  }
}

function buildShell() {
  const badges = [];
  const links = [];
  // Na barra inferior o contador fica sobre o ícone; na lateral, no fim da linha.
  const navLink = (route, compact) => {
    const badgeElement = route.path === "alertas" ? h("span", { class: "nav-badge", hidden: true }) : null;
    if (badgeElement) badges.push(badgeElement);
    const link = h(
      "a",
      { class: "nav-link", href: `#/${route.path}`, dataset: { route: route.path } },
      h("span", { class: "nav-pill" }, icon(route.icon), compact ? badgeElement : null),
      h("span", {}, route.label),
      compact ? null : badgeElement,
    );
    links.push(link);
    return link;
  };

  const brand = (subtitle) =>
    h(
      "a",
      { class: "brand", href: "#/inicio" },
      h("span", { class: "brand-mark" }, icon("eco")),
      h("span", { class: "brand-text" }, h("span", { class: "brand-eyebrow" }, "Monitor de Estufa"), h("span", { class: "brand-title" }, subtitle)),
    );

  const connection = h("span", { class: "connection", role: "status" }, h("span", { class: "dot", "aria-hidden": "true" }), h("span", { class: "connection-label" }, "Servidor conectado"));
  const userName = h("span", {}, user?.name || "");

  const view = h("main", { id: "view", class: "view", tabindex: -1 });
  const root = h(
    "div",
    { class: "shell" },
    h(
      "aside",
      { class: "sidebar", "aria-label": "Menu principal" },
      brand("Cura de tabaco"),
      h("nav", { class: "side-nav" }, ROUTES.map((route) => navLink(route, false))),
      h("div", { class: "sidebar-footer" }, h("p", { style: { fontWeight: 600 } }, userName), h("p", { class: "small muted" }, "Leituras atualizadas automaticamente.")),
    ),
    h(
      "div",
      { class: "main" },
      h("header", { class: "topbar" }, brand(""), h("div", { class: "topbar-actions" }, connection)),
      view,
    ),
    h("nav", { class: "bottom-nav", "aria-label": "Menu principal" }, ROUTES.map((route) => navLink(route, true))),
  );

  return { root, view, links, badges, connection, userName, mobileTitle: root.querySelector(".topbar .brand-title") };
}

function updateConnection(online) {
  if (!shell) return;
  shell.connection.classList.toggle("is-down", !online);
  shell.connection.querySelector(".connection-label").textContent = online ? "Servidor conectado" : "Sem conexão com o servidor";
  shell.connection.setAttribute("aria-label", online ? "Servidor conectado" : "Sem conexão com o servidor");
}

function renderRoute() {
  const { route, query } = parseHash();
  if (!route) {
    window.location.replace("#/inicio");
    return;
  }
  current?.destroy?.();
  const ctx = {
    query,
    navigate,
    setAlertCount,
    selectUnit: (unitId) => prefs.set({ unitId }),
    setUser: (updated) => {
      user = updated;
      if (shell) shell.userName.textContent = updated.name;
    },
    logout,
  };
  current = route.render(ctx);
  clear(shell.view, current.el);
  shell.links.forEach((link) => {
    if (link.dataset.route === route.path) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  shell.mobileTitle.textContent = route.title;
  document.title = `${route.label} · Monitor de Estufa`;
  window.scrollTo({ top: 0 });
}

function showApp() {
  shell = buildShell();
  clear(app, shell.root);
  updateConnection(api.online);
  renderRoute();
  refreshAlertCount();
  startBuzzerWatch();
}

function showLogin() {
  current?.destroy?.();
  current = null;
  shell = null;
  clearTimeout(badgeTimer);
  stopBuzzerWatch();
  document.title = "Entrar · Monitor de Estufa";
  clear(app, renderAuth({ onAuthenticated: start }));
}

function logout() {
  api.logout();
  user = null;
  showLogin();
}

async function start() {
  if (!api.isAuthenticated) {
    showLogin();
    return;
  }
  try {
    user = await api.get("/users/me");
    if (!window.location.hash) window.location.replace("#/inicio");
    showApp();
  } catch (error) {
    if (error.status === 401) showLogin();
    else {
      clear(
        app,
        h(
          "div",
          { class: "auth" },
          h(
            "div",
            { class: "card auth-card", style: { textAlign: "center" } },
            h("div", { class: "empty" }, icon("cloudOff"), h("h3", {}, "Servidor indisponível"), h("p", {}, error.message)),
            h("div", { class: "row", style: { justifyContent: "center" } },
              h("button", { class: "btn btn-primary", type: "button", onClick: start }, "Tentar de novo"),
              h("button", { class: "btn btn-outline", type: "button", onClick: showLogin }, "Alterar servidor"),
            ),
          ),
        ),
      );
    }
  }
}

api.on("expired", () => {
  if (shell) toast("Sua sessão expirou. Entre novamente.", "error");
  showLogin();
});
api.on("connection", updateConnection);
window.addEventListener("hashchange", () => {
  if (shell) renderRoute();
});

applyTheme();
start();
