# Assinar e notarizar o Cardflow.app

Pra distribuir o app pros voluntários sem aquele aviso de "desenvolvedor não identificado",
o macOS exige que ele seja **assinado** (com seu certificado) e **notarizado** (verificado pela Apple).
Você tem o **Apple Developer Program pago** e o **Xcode** — então é só configurar **uma vez** e depois
rodar um comando sempre que quiser gerar uma versão.

## Configuração (faz só uma vez)

### 1. Criar o certificado "Developer ID Application"
No **Xcode**: menu `Xcode → Settings… → Accounts` → selecione sua conta Apple → botão
`Manage Certificates…` → botão `+` (canto inferior esquerdo) → escolha **Developer ID Application**.
Pronto, o certificado fica no seu Keychain.

### 2. Descobrir seu Team ID
Em https://developer.apple.com/account → role até **Membership details** → copie o **Team ID**
(10 caracteres, ex.: `A1B2C3D4E5`).

### 3. Criar uma "senha de app" (app-specific password)
Em https://account.apple.com → faça login → seção **Segurança (Sign-In and Security)** →
**Senhas de app (App-Specific Passwords)** → `+` → dê um nome (ex.: "cardflow notary") →
copie a senha gerada (formato `abcd-efgh-ijkl-mnop`). Guarde — ela só aparece uma vez.

### 4. Guardar as credenciais no Keychain (um comando)
No Terminal, troque os 3 valores e rode:

```bash
xcrun notarytool store-credentials "cardflow-notary" \
    --apple-id SEU_EMAIL_APPLE \
    --team-id SEU_TEAM_ID \
    --password SUA_SENHA_DE_APP
```

Isso salva tudo com o nome `cardflow-notary` — você não precisa digitar de novo.

## Gerar uma versão assinada + notarizada (sempre que quiser)

```bash
bash scripts/sign-and-notarize.sh
```

O script empacota, acha seu certificado sozinho, assina (hardened runtime), envia pra Apple
notarizar (espera terminar), grampeia o ticket e confere no Gatekeeper. No fim, o
`Cardflow.app` abre em qualquer Mac com dois cliques, sem aviso.

## Se der errado
- **"Nenhum certificado Developer ID Application"** → faça o passo 1.
- **Notarização falhou / credencial** → você pulou o passo 4; rode o comando do passo 4.
- **A notarização demora** → é normal (a Apple processa em segundos a alguns minutos); o `--wait`
  segura até terminar.

## Distribuir
Depois de notarizado, comprima e envie o `Cardflow.app` (ex.: zipando pelo Finder, ou
`ditto -c -k --keepParent Cardflow.app Cardflow.zip`). O ticket vai grampeado, então funciona
até offline.
