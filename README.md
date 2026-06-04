# Cardflow

Copie seus cartões de câmera sem medo de perder gravação.

Você conecta o cartão e o disco onde quer guardar. O Cardflow copia tudo, confere arquivo por
arquivo e só avisa que pode formatar o cartão quando tem certeza de que cada foto e cada vídeo
chegou inteiro. Se quiser, copia pra dois lugares de uma vez, um disco e um backup.

Fiz pra quem grava culto, evento, show ou casamento e precisa esvaziar o cartão com segurança,
sem ficar arrastando pasta na mão e rezando pra nada corromper no caminho.

## O que ele faz

- Copia pra um disco e, se você quiser, pra um backup ao mesmo tempo.
- Depois de copiar, confere cada arquivo. Se algum não bateu, avisa em vermelho pra você não
  formatar o cartão.
- Quando está tudo certo, dá o sinal verde. Aí pode formatar tranquilo.
- Organiza as pastas do jeito que você configurar, por data, evento, câmera ou tipo de mídia.
- Se você rodar de novo no mesmo cartão, ele pula o que já copiou em vez de duplicar.
- Copia formatos de cinema (RED, Blackmagic, Sony, ARRI) sem mexer na estrutura de pastas que
  essas câmeras precisam.

## Instalar

1. Baixe o Cardflow.dmg na página de [Releases](../../releases).
2. Abra o arquivo e arraste o Cardflow pra pasta Aplicativos.
3. Na primeira vez que você ler um cartão, o Mac pergunta uma vez se o app pode acessar os
   discos. Clique em Permitir. Ele não pergunta de novo a cada cartão.

O app é assinado e reconhecido pela Apple, então abre normal, sem aquele aviso de
"desenvolvedor desconhecido".

## Como usar

1. Conecte o cartão e o disco onde quer salvar.
2. Escolha o disco de destino, e o de backup se for usar um.
3. Clique em Iniciar e espere.
4. Quando aparecer o verde, pode formatar o cartão com segurança.

## Atualizações

Quando você abre o app, ele dá uma olhada aqui no GitHub pra ver se saiu versão nova. Se saiu,
aparece um aviso pequeno com um botão de baixar. É só pegar o DMG novo e instalar por cima.

## Privacidade

O Cardflow trabalha offline. A única vez que ele usa a internet é nessa olhada pra ver se tem
versão nova, e mesmo aí só lê o número da versão. Seus arquivos nunca saem do seu computador, e
não tem cadastro nem rastreamento de nenhum tipo.

## Pra quem quer os detalhes técnicos

App nativo de macOS feito em Swift e SwiftUI, sem dependências externas.

### Como a conferência funciona

Não é um copiar e colar comum. Pra cada arquivo, o Cardflow calcula um hash xxHash64 da origem e
do que foi gravado em cada destino, e só marca como conferido quando os dois batem. Antes de
comparar, força um fsync pra garantir que os bytes saíram do cache e foram mesmo pro disco. Se a
conferência falha, o arquivo corrompido é apagado e a interface segura o sinal verde. O cartão
nunca aparece como seguro sem essa prova.

Outras garantias do motor:

- Não sobrescreve. Rodar de novo pula o que já está lá (mesmo hash) e separa arquivos de mesmo
  nome com conteúdo diferente em vez de passar por cima.
- Preserva cinema. RED (.RDM/.RDC/.R3D), BRAW (.braw mais sidecar), P2 e XAVC são copiados como
  estão, mantendo a árvore de pastas. Achatar quebraria o relink no editor.
- Recusa cópia e backup que sejam o mesmo disco físico (checa via DiskArbitration), porque isso
  não seria backup de verdade.
- Cada cartão gera um manifesto com o registro do que foi copiado: origem, destino e hash.

### Como o projeto está organizado

- `Sources/OffloadKit` é o motor, em Swift puro, sem interface: leitura do cartão, cópia,
  conferência, nomes por template, manifesto e memória de presets.
- `Sources/CardflowApp` é a interface em SwiftUI.
- `Sources/cardflow` e `Sources/CardflowCLI` são a versão de linha de comando, que usa o mesmo
  motor.

### Compilar do código

Precisa do Swift 6 (Xcode 16 ou as Command Line Tools).

```sh
swift build
swift run cardflow --help
bash scripts/make-app.sh
```

Pra gerar a versão assinada e empacotada em DMG, veja [`docs/notarizacao.md`](docs/notarizacao.md)
e os scripts em `scripts/`.

### Requisitos

macOS 14 ou mais novo.

## Licença

[MIT](LICENSE). Use, modifique e distribua à vontade, só mantendo o aviso de copyright.
