// Tela de entrada: login, cadastro e recuperação de senha.

import { api } from "../api.js";
import { button, clear, field, h, icon, openModal, toast, withBusy } from "../dom.js";

export function renderAuth({ onAuthenticated }) {
  const root = h("div", { class: "auth" });
  const card = h("div", { class: "card auth-card" });
  root.append(card);

  let mode = "login";

  function brand(subtitle) {
    return h(
      "div",
      { class: "auth-brand" },
      h("div", { class: "brand-mark" }, icon("eco")),
      h("div", {}, h("p", { class: "eyebrow" }, "Monitor de Estufa"), h("h1", {}, subtitle)),
    );
  }

  function tabs() {
    const make = (value, label) =>
      h(
        "button",
        {
          class: "tab",
          type: "button",
          role: "tab",
          "aria-selected": String(mode === value),
          onClick: () => {
            mode = value;
            render();
          },
        },
        label,
      );
    return h("div", { class: "tabs", role: "tablist", style: { marginBottom: "20px" } }, make("login", "Entrar"), make("register", "Criar conta"));
  }

  function serverFooter() {
    return h(
      "p",
      { class: "auth-footer" },
      "Servidor: ",
      h("span", { class: "num" }, api.base),
      " · ",
      h("button", { class: "link-button", type: "button", onClick: openServerDialog }, "Alterar"),
    );
  }

  function errorBox() {
    return h("div", { class: "form-error", role: "alert", hidden: true });
  }

  function showError(box, error) {
    box.textContent = error.message;
    box.hidden = false;
  }

  function loginForm() {
    const login = h("input", { class: "input", name: "login", autocomplete: "username", required: true });
    const password = h("input", { class: "input", name: "password", type: "password", autocomplete: "current-password", required: true });
    const error = errorBox();
    const submit = button("Entrar", { variant: "btn-primary btn-block", type: "submit" });
    const form = h(
      "form",
      {
        class: "form",
        onSubmit: async (event) => {
          event.preventDefault();
          error.hidden = true;
          try {
            await withBusy(submit, () => api.login(login.value.trim(), password.value));
            onAuthenticated();
          } catch (exception) {
            showError(error, exception);
          }
        },
      },
      error,
      field({ label: "Login", input: login }),
      field({ label: "Senha", input: password }),
      submit,
      h(
        "p",
        { class: "small", style: { textAlign: "center" } },
        h("button", { class: "link-button", type: "button", onClick: () => { mode = "forgot"; render(); } }, "Esqueci minha senha"),
      ),
    );
    return form;
  }

  function registerForm() {
    const name = h("input", { class: "input", name: "name", autocomplete: "name", required: true, minlength: 2 });
    const login = h("input", { class: "input", name: "login", autocomplete: "username", required: true, minlength: 3 });
    const password = h("input", { class: "input", name: "password", type: "password", autocomplete: "new-password", required: true, minlength: 6 });
    const error = errorBox();
    const submit = button("Criar conta", { variant: "btn-primary btn-block", type: "submit" });
    return h(
      "form",
      {
        class: "form",
        onSubmit: async (event) => {
          event.preventDefault();
          error.hidden = true;
          try {
            await withBusy(submit, () => api.register(name.value.trim(), login.value.trim(), password.value));
            toast("Conta criada. Bem-vindo!", "success");
            onAuthenticated();
          } catch (exception) {
            showError(error, exception);
          }
        },
      },
      error,
      field({ label: "Seu nome", input: name }),
      field({ label: "Login", input: login, hint: "Mínimo de 3 caracteres." }),
      field({ label: "Senha", input: password, hint: "Pelo menos 6 caracteres." }),
      submit,
    );
  }

  function forgotForm() {
    const login = h("input", { class: "input", autocomplete: "username", required: true });
    const code = h("input", { class: "input", autocomplete: "one-time-code" });
    const password = h("input", { class: "input", type: "password", autocomplete: "new-password", minlength: 6 });
    const error = errorBox();
    const info = h("div", { class: "form-success", hidden: true });
    const stepTwo = h("div", { class: "form", hidden: true },
      field({ label: "Código de redefinição", input: code }),
      field({ label: "Nova senha", input: password, hint: "Pelo menos 6 caracteres." }),
    );
    const submit = button("Gerar código", { variant: "btn-primary btn-block", type: "submit" });
    let requested = false;

    return h(
      "form",
      {
        class: "form",
        onSubmit: async (event) => {
          event.preventDefault();
          error.hidden = true;
          try {
            if (!requested) {
              const result = await withBusy(submit, () => api.post("/auth/password-reset/request", { login: login.value.trim() }, { auth: false }));
              requested = true;
              stepTwo.hidden = false;
              submit.querySelector("span:last-child").textContent = "Salvar nova senha";
              if (result.reset_token) {
                code.value = result.reset_token;
                info.textContent = "Código preenchido abaixo (modo de desenvolvimento). Vale por 15 min.";
              } else {
                info.textContent = "Se o login existir, o código foi enviado ao responsável pelo sistema. Vale por 15 min.";
              }
              info.hidden = false;
              password.focus();
            } else {
              await withBusy(submit, () =>
                api.post(
                  "/auth/password-reset/confirm",
                  { login: login.value.trim(), reset_token: code.value.trim(), new_password: password.value },
                  { auth: false },
                ),
              );
              toast("Senha atualizada. Entre com a nova senha.", "success");
              mode = "login";
              render();
            }
          } catch (exception) {
            showError(error, exception);
          }
        },
      },
      error,
      info,
      field({ label: "Login", input: login }),
      stepTwo,
      submit,
      h(
        "p",
        { class: "small", style: { textAlign: "center" } },
        h("button", { class: "link-button", type: "button", onClick: () => { mode = "login"; render(); } }, "Voltar para o login"),
      ),
    );
  }

  function openServerDialog() {
    const input = h("input", { class: "input num", value: api.base, inputmode: "url", placeholder: "http://192.168.1.2:8000" });
    const status = h("p", { class: "field-hint" }, "Endereço do computador que roda o servidor.");
    openModal({
      title: "Endereço do servidor",
      body: h("div", { class: "form" }, field({ label: "URL da API", input }), status),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const ok = await api.testConnection(input.value);
            if (!ok) throw new Error(`Não houve resposta de ${input.value}. Confira o endereço e se o backend está ligado.`);
            api.setBase(input.value);
            toast("Servidor conectado.", "success");
            close();
            render();
          },
        },
      ],
    });
  }

  function render() {
    const titles = { login: "Entrar", register: "Criar conta", forgot: "Recuperar senha" };
    const form = mode === "login" ? loginForm() : mode === "register" ? registerForm() : forgotForm();
    clear(card, brand(titles[mode]), mode === "forgot" ? null : tabs(), form, serverFooter());
    card.querySelector("input")?.focus();
  }

  render();
  return root;
}
