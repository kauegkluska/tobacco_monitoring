// Perfil: conta, preferências de exibição, servidor e ajuda rápida.

import { api } from "../api.js";
import { playBeep } from "../buzzer.js";
import { banner, button, clear, field, h, icon, loadingState, segmented, toast, withBusy } from "../dom.js";
import { prefs } from "../store.js";

export function renderProfile(ctx) {
  const root = h("div", { class: "page" }, loadingState());
  let destroyed = false;

  async function load() {
    try {
      const user = await api.get("/users/me");
      if (!destroyed) draw(user);
    } catch (error) {
      if (!destroyed) clear(root, banner("crit", "cloudOff", "Não foi possível carregar o perfil", error.message, [button("Tentar de novo", { onClick: load })]));
    }
  }

  function accountCard(user) {
    const name = h("input", { class: "input", value: user.name, maxlength: 100, autocomplete: "name" });
    const save = button("Salvar nome", { variant: "btn-primary", type: "submit" });
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("person"), "Sua conta")),
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              const updated = await withBusy(save, () => api.patch("/users/me", { name: name.value.trim() }));
              ctx.setUser(updated);
              toast("Nome atualizado.", "success");
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({ label: "Nome", input: name }),
        h("dl", { class: "details" }, h("div", {}, h("dt", {}, "Login"), h("dd", {}, user.login))),
        h("div", { class: "form-actions" }, save),
      ),
    );
  }

  function passwordCard() {
    const current = h("input", { class: "input", type: "password", autocomplete: "current-password", required: true });
    const next = h("input", { class: "input", type: "password", autocomplete: "new-password", minlength: 6, required: true });
    const save = button("Trocar senha", { variant: "btn-primary", type: "submit" });
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("lock"), "Senha")),
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              await withBusy(save, () => api.post("/users/me/password", { current_password: current.value, new_password: next.value }));
              current.value = "";
              next.value = "";
              toast("Senha alterada.", "success");
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({ label: "Senha atual", input: current }),
        field({ label: "Nova senha", input: next, hint: "Pelo menos 6 caracteres." }),
        h("div", { class: "form-actions" }, save),
      ),
    );
  }

  function preferencesCard() {
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("palette"), "Exibição")),
      h(
        "div",
        { class: "form" },
        h(
          "div",
          { class: "field" },
          h("span", { class: "field-label" }, "Unidade de temperatura"),
          segmented(
            [
              { value: "F", label: "Fahrenheit (°F)" },
              { value: "C", label: "Celsius (°C)" },
            ],
            prefs.unit,
            (value) => {
              prefs.set({ unit: value });
              toast(`Temperaturas em ${value === "F" ? "Fahrenheit" : "Celsius"}.`, "success");
            },
            "Unidade de temperatura",
          ),
          h("span", { class: "field-hint" }, "O sensor mede em Celsius; a conversão é feita só na tela."),
        ),
        h(
          "div",
          { class: "field" },
          h("span", { class: "field-label" }, "Tema"),
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
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("campaign"), "Aviso sonoro")),
      h(
        "div",
        { class: "form" },
        h(
          "div",
          { class: "field" },
          h("span", { class: "field-label" }, "Tocar também neste aparelho"),
          segmented(
            [
              { value: true, label: "Ligado" },
              { value: false, label: "Desligado" },
            ],
            prefs.sound,
            (value) => {
              prefs.set({ sound: value });
              if (value) playBeep();
              toast(value ? "O painel vai bipar junto com o gateway." : "O painel só mostra o aviso na tela.", "success");
            },
            "Tocar o aviso sonoro neste aparelho",
          ),
          h(
            "span",
            { class: "field-hint" },
            "Quando o gateway tocar o aviso (uma saída ligou), o painel bipa e o celular vibra. Funciona com o painel aberto. Os modos das saídas ficam no Início.",
          ),
        ),
        h("div", { class: "form-actions" }, button("Testar som", { variant: "btn-outline", iconName: "volumeUp", onClick: playBeep })),
      ),
    );
  }

  function serverCard() {
    const input = h("input", { class: "input num", value: api.base, inputmode: "url" });
    const save = button("Testar e salvar", { variant: "btn-primary", type: "submit" });
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("server"), "Servidor")),
      h(
        "form",
        {
          class: "form",
          onSubmit: async (event) => {
            event.preventDefault();
            try {
              const ok = await withBusy(save, () => api.testConnection(input.value));
              if (!ok) throw new Error(`Não houve resposta de ${input.value}.`);
              api.setBase(input.value);
              toast("Servidor salvo. Entre novamente.", "success");
              ctx.logout();
            } catch (error) {
              toast(error.message, "error");
            }
          },
        },
        field({
          label: "Endereço da API",
          input,
          hint: "Endereço do computador que roda o backend, por exemplo http://192.168.0.14:8000. O gateway acha esse endereço sozinho pela rede; aqui ele só vale para este navegador.",
        }),
        h("div", { class: "form-actions" }, save),
      ),
    );
  }

  function helpCard() {
    const statuses = [
      ["Sensor online", "O sender enviou uma leitura nos últimos 90 segundos."],
      ["Sensor offline", "Nenhuma leitura recente. Verifique energia, antena LoRa e o Wi-Fi do gateway."],
      ["Secagem parada", "O sensor pode estar enviando, mas as leituras não são gravadas nem geram alertas."],
      ["Fases da cura", "Amarelação, Murchamento, Secagem da folha e Secagem do talo. Cada fase tem a própria faixa de temperatura e umidade; você avança quando as folhas estiverem prontas."],
      ["Alerta de atenção", "Valor fora do esperado para a fase, aquecimento rápido ou sensor sem resposta."],
      ["Alerta crítico", "Temperatura ou umidade em nível perigoso para a fase, ou estufa sem leituras há 5 minutos. Exige atenção imediata."],
      ["Emergência", "Temperatura acima de 80 °C na secagem do talo."],
      ["Saída no automático", "Liga quando o valor sai da faixa da fase e desliga quando volta com folga. Com a secagem parada, fica desligada."],
      ["Aviso sonoro", "O gateway bipa por 2 segundos sempre que uma saída liga."],
    ];
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("help"), "Como funciona")),
      h(
        "ol",
        { class: "flow" },
        h("li", {}, h("strong", {}, icon("thermostat"), "1. Sender"), h("span", { class: "small text-2" }, "Na estufa, lê temperatura e umidade (SHT40) e transmite por rádio LoRa.")),
        h("li", {}, h("strong", {}, icon("sensors"), "2. Receiver"), h("span", { class: "small text-2" }, "O gateway recebe o rádio, envia as leituras ao servidor pelo Wi-Fi e recebe de volta o comando das saídas.")),
        h("li", {}, h("strong", {}, icon("dashboard"), "3. Painel"), h("span", { class: "small text-2" }, "O servidor grava o histórico, confere a faixa da fase da cura e mostra tudo aqui.")),
      ),
      h("div", { class: "divider" }),
      h(
        "dl",
        { class: "glossary" },
        statuses.map(([term, description]) => h("div", {}, h("dt", { style: { fontWeight: 600 } }, term), h("dd", {}, description))),
      ),
    );
  }

  function draw(user) {
    clear(
      root,
      h("div", { class: "page-header" }, h("div", {}, h("p", { class: "eyebrow" }, "Perfil"), h("h1", {}, user.name))),
      h("div", { class: "grid grid-2" }, h("div", { class: "stack" }, accountCard(user), preferencesCard(), soundCard()), h("div", { class: "stack" }, passwordCard(), serverCard())),
      helpCard(),
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
