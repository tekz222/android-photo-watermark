# Photo Watermark

Aplicativo Android para aplicar a sua **logo no canto** de qualquer quantidade de
fotos de uma só vez, com um espaçamento (padding) elegante como em fotografias
profissionais — e depois salvar todas na galeria.

## Como funciona

1. **Selecione as fotos** — escolha quantas fotos quiser (seleção múltipla).
2. **Envie a logo** — depois de escolher as fotos, selecione a imagem da sua logo
   (de preferência um PNG com fundo transparente).
3. **Escolha o canto** — superior esquerdo, superior direito, inferior esquerdo ou
   inferior direito.
4. **Ajuste fino** (opcional) — tamanho da logo e distância da borda.
5. **Aplicar e salvar todas** — a logo é desenhada em cada foto e todas são salvas
   em `Imagens/Watermarked` na galeria do aparelho.

## Detalhes técnicos

- **100% Kotlin + Jetpack Compose** (Material 3).
- Seleção de imagens via **Photo Picker** (`PickMultipleVisualMedia`), sem precisar
  de permissão de armazenamento para *ler*.
- Salvamento via **MediaStore** (armazenamento com escopo). Em Android 10+ nenhuma
  permissão é necessária para salvar; em Android 9 e abaixo o app pede
  `WRITE_EXTERNAL_STORAGE`.
- A logo é dimensionada em relação ao **menor lado** da foto, então fica proporcional
  tanto em paisagem quanto em retrato, preservando a proporção (aspect ratio) da logo.
- A orientação **EXIF** das fotos é respeitada, e imagens muito grandes são
  reduzidas com segurança para evitar `OutOfMemoryError`.
- O processamento roda fora da thread principal (coroutines) com barra de progresso.

### Padrões / valores ajustáveis

| Parâmetro            | Padrão | Intervalo |
|----------------------|--------|-----------|
| Canto                | Inferior direito | 4 cantos |
| Tamanho da logo      | 18% do menor lado | 5%–40% |
| Distância da borda   | 4% do menor lado  | 0%–15% |

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
├── MainActivity.kt        # UI em Jetpack Compose (fluxo em 4 passos)
├── WatermarkViewModel.kt  # estado da tela + processamento em lote
└── WatermarkEngine.kt     # carregar, compor a logo e salvar na galeria
```

## Licença

MIT
