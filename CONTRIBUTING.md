# Como contribuir

Obrigado pelo interesse no Cardflow. Algumas coisas que ajudam a manter o app confiável.

## Rodar e testar

O projeto é SwiftPM. O motor (`OffloadKit`) é Swift puro e sem dependências externas; o app
macOS usa Sparkle só para atualização in-app. Precisa de Xcode (macOS 14+).

```bash
swift build          # compila o motor, o app e a CLI
swift test           # roda a suíte (todos os testes do motor)
```

Todo PR deve deixar `swift test` verde. O CI roda isso automaticamente, mas rode local antes.

## Como o código é organizado

- **`OffloadKit`** é o motor: cópia, verificação por hash, detecção de cartão, nomes, manifesto.
  É Swift puro, sem `SwiftUI`/`AppKit`, e roda sem interface (headless). **Toda lógica de regra de
  negócio vive aqui e é coberta por teste.** Se você mexe no comportamento, escreva o teste no
  diretório `Tests/OffloadKitTests`.
- **`CardflowApp`** é a interface (`SwiftUI`). Ela não é testável sem tela, então é validada por
  build e por inspeção visual. Evite colocar regra de negócio aqui — extraia pro `OffloadKit` e teste lá.
- **`cardflow`/`CardflowCLI`** é a versão de linha de comando do mesmo motor.

Regra de ouro: este é um app cujo trabalho é **não perder footage**. Qualquer mudança em cópia,
verificação ou na decisão de "pode formatar o cartão" precisa de teste cobrindo o caminho de falha,
não só o caminho feliz.

## Por que `language mode .v5`

Os alvos usam o modo de linguagem `.v5` do Swift (mesmo com tools do Swift 6). O motor de cópia tem
invariantes de thread única em `claimed`/`bytesDone` e uma fila de verificação cuidadosamente isolada;
migrar pra verificação estrita do Swift 6 é um trabalho à parte que não muda o comportamento. Está
documentado aqui pra não parecer descuido.

## Estilo

Siga o que já está no código: comentários explicam o **porquê** (não o óbvio), nomes em português
onde fazem sentido pro domínio, textos de interface sempre acentuados e sem jargão desnecessário.
