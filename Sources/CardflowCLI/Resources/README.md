# Localização da CLI

A CLI (`cardflow`) roda via `swift run`, sem `.app` — então não passa pelo
`scripts/make-app.sh`, que é onde o app GUI compila os `.xcstrings`. E o
`swift build` **não** compila String Catalog: o `.bundle` do target sai só com o
`.xcstrings` cru, sem `.lproj`, e o `String(localized:bundle:.module)` não
acharia as traduções.

Por isso, aqui os `.strings` ficam **versionados à mão**. O fluxo:

1. Editar as strings em `Localizable.xcstrings` (fonte única, editável no Xcode).
2. Recompilar os `.lproj`:

   ```sh
   xcrun xcstringstool compile Sources/CardflowCLI/Resources/Localizable.xcstrings \
     --output-directory Sources/CardflowCLI/Resources/
   ```

3. Commitar os três `<lang>.lproj/Localizable.strings` gerados.

O `Localizable.xcstrings` está **excluído** do target no `Package.swift` (fica só
como fonte de edição). Quem vai pro bundle `.module` são os `.lproj` — esses o
`.process("Resources")` empacota, e o runtime resolve pelo idioma do sistema.
