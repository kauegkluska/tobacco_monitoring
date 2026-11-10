// Ajustes: exibição, aviso sonoro, conta, servidor e legenda das situações.

import { api } from "../api.js";
import { playBeep } from "../buzzer.js";
import { badge, banner, button, clear, field, h, icon, loadingState, segmented, toast, withBusy } from "../dom.js";
import { prefs } from "../store.js";

const LEGEND = [
  ["crit", "Vá à estufa", "error", "Risco para a cura. Aja agora."],
  ["warn", "Fique de olho", "warning", "Há um alerta aberto. Acompanhe a estufa."],
  ["warn", "Leitura duvidosa", "help", "O sensor pode estar com problema. Confira no termômetro da estufa."],
  ["warn", "Fora do esperado", "tune", "Algum valor saiu do esperado, ainda sem alerta."],
  ["offline", "Sem notícias", "cloudOff", "A estufa parou de mandar leituras."],
  ["offline", "Sem conexão", "cloudOff", "Este aparelho não consegue falar com o monitor."],
  ["ok", "Pode avançar", "chevronRight", "Tempo e temperatura atingidos. Olhe as folhas."],
  ["ok", "Tudo certo", "check", "Dentro do esperado para a fase, com leitura recente."],
  ["ok", "Finalizada", "checkCircle", "Cura concluída."],
  ["neutral", "Aguardando", "clock", "Secagem ligada, esperando a primeira leitura."],
  ["neutral", "Parada", "stop", "Secagem desligada: nada é gravado e não há avisos."],
  ["neutral", "Sem sensor", "linkOff", "Falta vincular o sensor a esta estufa."],
];

export function renderSettings(ctx) {
  const root = h("div", { class: "page" }, loadingState());
  let destroyed = false;

  async function load() {
    try {
      const user = await api.get("/users/me");
      if (!destroyed) draw(user);
    } catch (error) {
      if (!destroyed) clear(root, banner("crit", "cloudOff", "Não foi possível carregar os ajustes", error.message, [button("Tentar de novo", { onClick: load })]));
    }
  }

  const card = (title, iconName, ...children) => h("section", { class: "card" }, h("div", { class: "card-header" }, h("h2", {}, icon(iconName), title)), ...children);
  const choice = (label, control) => h("div", { class: "field" }, h("span", { class: "field-label" }, label), control);

  function displayCard() {
    return card(
      "Exibição",
      "palette",
      h(
        "div",
        { class: "form" },
        choice(
          "Temperatura",
          segmented(
            [
              { value: "F", label: "°F" },
              { value: "C", label: "°C" },
            ],
            prefs.unit,
            (value) => prefs.set({ unit: value }),
            "Unidade de temperatura",
          ),
        ),
        choice(
          "Tema",
          segmented(
            [
              { value: "auto", label: "Automático" },
              { value: "light", label: "Claro" },
              { value: "dark", label: "Escuro" },
            ],
            prefs.theme,
            (value) => prefs.set({ theme: value }),
            "Tema",
          ),
        ),
      ),
    );
  }

  function soundCard() {
    return card(
      "Apito",
      "volumeUp",
      h(
        "div",
        { class: "form" },
        choice(
          "Apitar neste aparelho quando a ventoinha ou o flap ligar",
          segmented(
            [
              { value: true, label: "Ligado" },
              { value: false, label: "Desligado" },
            ],
            prefs.sound,
            (value) => {
              prefs.set({ sound: value });
              if (value) playBeep();
            },
            "Apitar neste aparelho",
          ),
        ),
        h("div", {}, button("Testar som", { variant: "btn-outline btn-sm", iconName: "volumeUp", onClick: playBeep })),
      ),
    );
  }

  function accountCard(user) {
    const name = h("input", { class: "input", value: user.name, maxlength: 100, autocomplete: "name" });
    const saveName = button("Salvar nome", { variant: "btn-outline", type: "submit" });
    const current = h("input", { class: "input", type: "password", autocomplete: "current-password", required: true });
    const next = h("input", { class: "input", type: "password", autocomplete: "new-password", minlength: 6, required: true });
    const savePassword = button("Trocar senha", { variant: "btn-outline", type: "submit" });
    return card(
      "Conta",
      "person",
      h("p", { class: "small muted card-intro" }, `Usuário: ${user.login}`),
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              const updated = await withBusy(saveName, () => api.patch("/users/me", { name: name.value.trim() }));
              ctx.setUser(updated);
              toast("Nome salvo.", "success");
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({ label: "Nome", input: name }),
        h("div", { class: "form-actions" }, saveName),
      ),
      h("div", { class: "divider" }),
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              await withBusy(savePassword, () => api.post("/users/me/password", { current_password: current.value, new_password: next.value }));
              current.value = "";
              next.value = "";
              toast("Senha alterada.", "success");
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({ label: "Senha atual", input: current }),
        field({ label: "Nova senha", input: next, hint: "Mínimo de 6 caracteres." }),
        h("div", { class: "form-actions" }, savePassword),
      ),
    );
  }

  function serverCard() {
    const input = h("input", { class: "input num", value: api.base, inputmode: "url", placeholder: "http://192.168.0.14:8000" });
    const save = button("Testar e salvar", { variant: "btn-primary", type: "submit" });
    return card(
      "Avançado",
      "server",
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              const ok = await withBusy(save, () => api.testConnection(input.value));
              if (!ok) throw new Error(`Sem resposta de ${input.value}.`);
              api.setBase(input.value);
              toast("Endereço salvo. Entre novamente.", "success");
              ctx.logout();
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({ label: "Endereço do monitor", input, hint: "Só mude isto se o responsável pelo sistema pedir." }),
        h("div", { class: "form-actions" }, save),
      ),
    );
  }

  function legendCard() {
    return card(
      "Legenda",
      "help",
      h(
        "dl",
        { class: "legend" },
        LEGEND.map(([kind, label, iconName, text]) => h("div", {}, h("dt", {}, badge(kind, label, iconName)), h("dd", { class: "small text-2" }, text))),
      ),
    );
  }

  function draw(user) {
    clear(
      root,
      h("div", { class: "grid grid-2" }, h("div", { class: "stack" }, displayCard(), soundCard(), legendCard()), h("div", { class: "stack" }, accountCard(user), serverCard())),
      h("div", {}, button("Sair da conta", { variant: "btn-danger", iconName: "logout", onClick: ctx.logout })),
    );
  }

  load();
  return {
    el: root,
    destroy() {
      destroyed = true;
    },
  };
}
