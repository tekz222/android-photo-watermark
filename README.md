# Photo Watermark

Aplicativo Android para aplicar **logos** em qualquer quantidade de fotos de uma
só vez, em três posições independentes:

- uma fileira de logos na **base** (encostadas, da esquerda para a direita);
- uma fileira de logos no **canto superior esquerdo** (mesmo layout);
- uma única **logo principal** no **canto superior direito**.

Depois é só salvar todas na galeria.

## Como funciona

1. **Adicione as fotos** — escolha quantas quiser (seleção múltipla). Pode ir
   adicionando aos poucos e **remover** qualquer foto pelo “✕” na miniatura.
2. **Logos da base** — selecione **uma ou mais** logos (de preferência PNG com
   fundo transparente). Ficam numa fileira no rodapé, **encostadas** da esquerda
   para a direita. Ajuste tamanho, distância da borda inferior e da esquerda.
3. **Logos do canto superior esquerdo** — mesma ideia da base, mas no topo.
   Ajuste tamanho, distância do topo e da esquerda.
4. **Logo principal (canto superior direito)** — escolha **uma** logo. Dá para
   trocar ou remover quando quiser, e ajustar o tamanho e a distância do canto.
5. **Pré-visualização** — veja a 1ª foto já com as logos, atualizando ao vivo
   conforme você muda os ajustes.
6. **Aplicar e salvar tudo** — cada foto recebe as logos e é salva em
   `Imagens/Watermarked` na galeria do aparelho.

## Detalhes técnicos

- **100% Kotlin + Jetpack Compose** (Material 3).
- Seleção de imagens via **Photo Picker** (`PickMultipleVisualMedia`), sem precisar
  de permissão de armazenamento para *ler*.
- Salvamento via **MediaStore** (armazenamento com escopo). Em Android 10+ nenhuma
  permissão é necessária para salvar; em Android 9 e abaixo o app pede
  `WRITE_EXTERNAL_STORAGE`.
- As logos são dimensionadas pela **altura**, em relação ao **menor lado** da foto,
  então ficam proporcionais tanto em paisagem quanto em retrato. Cada logo mantém
  sua própria proporção. As fileiras (base e canto superior esquerdo) ficam
  **encostadas** (sem espaço entre elas); a logo principal fica alinhada ao canto
  superior direito.
- A orientação **EXIF** das fotos é respeitada, e imagens muito grandes são
  reduzidas com segurança para evitar `OutOfMemoryError`.
- O processamento (e o preview) rodam fora da thread principal (coroutines).

### Padrões / valores ajustáveis

| Parâmetro                                | Padrão | Intervalo |
|------------------------------------------|--------|-----------|
| Base — tamanho (altura)                  | 12% do menor lado | 5%–30% |
| Base — distância da borda inferior       | 3% do menor lado  | 0%–15% |
| Base — distância da borda esquerda       | 3% do menor lado  | 0%–15% |
| Canto sup. esquerdo — tamanho (altura)   | 12% do menor lado | 5%–30% |
| Canto sup. esquerdo — distância do topo  | 3% do menor lado  | 0%–15% |
| Canto sup. esquerdo — distância esquerda | 3% do menor lado  | 0%–15% |
| Logo principal — tamanho (altura)        | 12% do menor lado | 5%–30% |
| Logo principal — distância do canto      | 4% do menor lado  | 0%–15% |

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
