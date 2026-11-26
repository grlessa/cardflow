# Assinar e notarizar o Cardflow.app

Pra distribuir o app pros voluntários sem aquele aviso de "desenvolvedor não identificado",
o macOS exige que ele seja **assinado** (com seu certificado) e **notarizado** (verificado pela Apple).
Com o **Apple Developer Program pago** e o **Xcode**, é só configurar **uma vez** e depois
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
copie a senha gerada (formato `abcd-efgh-ijkl-mnop`). Guarde com cuidado, pois ela só aparece uma vez.

### 4. Guardar as credenciais no Keychain (um comando)
No Terminal, troque os 3 valores e rode:

```bash
xcrun notarytool store-credentials "cardflow-notary" \
    --apple-id SEU_EMAIL_APPLE \
    --team-id SEU_TEAM_ID \
    --password SUA_SENHA_DE_APP
```

Isso salva tudo com o nome `cardflow-notary`, para não precisar digitar de novo.

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
Depois de notarizar o `Cardflow.app`, gere e notarize o instalador DMG com `bash scripts/make-dmg.sh`.
O ticket vai grampeado no app e no DMG, então funciona até offline.

## Atualização in-app (Sparkle)

O app se atualiza sozinho pelo Sparkle: ele lê o feed `https://cardflow.lessafilms.com/appcast.xml`
e, quando há versão nova, baixa o DMG, confere a assinatura e instala. Pra isso o pipeline ganhou
três coisas: o `Sparkle.framework` embutido no bundle, uma chave que assina cada atualização e o
feed publicado no site.

### Configuração (faz só uma vez)

**1. Baixar as ferramentas do Sparkle.** Use a MESMA versão da dependência (veja em `Package.resolved`).
Troque `2.9.3` se for diferente:

```bash
VER=2.9.3
curl -L -o /tmp/Sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/$VER/Sparkle-$VER.tar.xz"
mkdir -p scripts/sparkle-bin && tar -xf /tmp/Sparkle.tar.xz -C /tmp
cp /tmp/bin/generate_keys /tmp/bin/sign_update scripts/sparkle-bin/ && chmod +x scripts/sparkle-bin/*
```

A pasta `scripts/sparkle-bin/` é ignorada pelo git (são binários).

**2. Gerar o par de chaves.** A chave privada fica no seu Keychain; a pública vai no app.

```bash
scripts/sparkle-bin/generate_keys
```

A chave pública atual já está em `SUPublicEDKey` dentro de `scripts/make-app.sh`. Se gerar um par novo,
atualize esse valor no script e faça um backup da chave privada num cofre, porque sem ela não dá mais
pra assinar atualizações:

```bash
scripts/sparkle-bin/generate_keys -x /tmp/sparkle_private_key.pem   # guarde no cofre e apague do /tmp
```

### A cada release

A assinatura agora é de dentro pra fora (o `sign-and-notarize.sh` assina os componentes do Sparkle
antes do app, sem `--deep`). O fluxo fica:

1. `bump` da versão em `Sources/OffloadKit/OffloadKit.swift`.
2. `bash scripts/sign-and-notarize.sh` (monta com o Sparkle embutido, assina, notariza, grampeia).
3. `bash scripts/make-dmg.sh` (gera o `Cardflow.dmg`).
4. `gh release create vX.Y.Z --repo grlessa/cardflow --target <sha>` anexando o `Cardflow.dmg`.
5. `scripts/make-appcast.sh Cardflow.dmg vX.Y.Z notas-da-release.html` (assina o DMG com `sign_update`
   e gera `docs/appcast.xml`).
6. Publicar `docs/appcast.xml` no repositório público. O GitHub Pages serve o feed e os apps instalados
   pegam a versão nova.

As notas da release (`notas-da-release.html`) são escritas à mão, em pt-BR, sem travessão.
