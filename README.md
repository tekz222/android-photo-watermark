# Photo Watermark

Aplicativo Android para aplicar **uma ou várias logos** em qualquer quantidade de
fotos de uma só vez. As logos ficam **em linha, centralizadas e igualmente
espaçadas na parte de baixo** da foto, com uma margem elegante como em
fotografias profissionais — e depois é só salvar todas na galeria.

## Como funciona

1. **Adicione as fotos** — escolha quantas quiser (seleção múltipla). Pode ir
   adicionando aos poucos e **remover** qualquer foto pelo “✕” na miniatura.
2. **Envie as logos** — selecione **uma ou mais** logos (de preferência PNG com
   fundo transparente). Todas entram numa fileira horizontal centralizada no
   rodapé. Também dá para remover logos individualmente.
3. **Ajustes** — tamanho das logos, distância da borda inferior e espaçamento
   entre as logos.
4. **Pré-visualização** — veja a 1ª foto já com as logos, atualizando ao vivo
   conforme você muda os ajustes.
5. **Aplicar e salvar tudo** — cada foto recebe a fileira de logos e é salva em
   `Imagens/Watermarked` na galeria do aparelho.

## Detalhes técnicos

- **100% Kotlin + Jetpack Compose** (Material 3).
- Seleção de imagens via **Photo Picker** (`PickMultipleVisualMedia`), sem precisar
  de permissão de armazenamento para *ler*.
- Salvamento via **MediaStore** (armazenamento com escopo). Em Android 10+ nenhuma
  permissão é necessária para salvar; em Android 9 e abaixo o app pede
  `WRITE_EXTERNAL_STORAGE`.
- As logos são dimensionadas pela **altura**, em relação ao **menor lado** da foto,
  então a fileira fica proporcional tanto em paisagem quanto em retrato. Cada logo
  mantém sua própria proporção, e a fileira inteira é centralizada; se for mais
  larga que a foto, é reduzida automaticamente para caber.
- A orientação **EXIF** das fotos é respeitada, e imagens muito grandes são
  reduzidas com segurança para evitar `OutOfMemoryError`.
- O processamento (e o preview) rodam fora da thread principal (coroutines).

### Padrões / valores ajustáveis

| Parâmetro                    | Padrão | Intervalo |
|------------------------------|--------|-----------|
| Tamanho das logos (altura)   | 12% do menor lado | 5%–30% |
| Distância da borda inferior  | 5% do menor lado  | 0%–15% |
| Espaçamento entre logos      | 4% do menor lado  | 0%–15% |

## Como compilar

Requisitos: Android Studio (Koala ou mais recente) ou o Android SDK com a
command-line.

```bash
# build de debug
./gradlew assembleDebug

# instalar em um dispositivo/emulador conectado
./gradlew installDebug
```

O APK gerado fica em `app/build/outputs/apk/debug/app-debug.apk`.

- `minSdk` 24 (Android 7.0) · `targetSdk`/`compileSdk` 34 · AGP 8.5.2 · Kotlin 1.9.24

## Estrutura

```
app/src/main/java/com/tekz/watermark/
├── MainActivity.kt        # UI em Jetpack Compose (fotos, logos, ajustes, preview)
├── WatermarkViewModel.kt  # estado da tela + processamento em lote
└── WatermarkEngine.kt     # carregar, compor a fileira de logos e salvar na galeria
```

## Licença

MIT
