# Photo Watermark — Flutter (iOS + Android)

Versão multiplataforma do app, escrita em **Flutter/Dart**, para rodar no
**iPhone** (e também Android). A composição das imagens é feita em Dart puro
(pacote `image`), então o resultado é idêntico nas duas plataformas.

## Recursos

- Várias fotos de uma vez; logos na **base**, no **canto superior esquerdo** e
  uma **logo principal** no canto superior direito.
- Logos repetíveis (a mesma logo várias vezes) e **reordenáveis** (arraste).
- **Tamanho** e **distância da esquerda** são compartilhados entre as logos de
  cima e de baixo; cada fileira tem sua própria distância da borda (superior/
  inferior).
- Pré-visualização ao vivo das **primeiras 5 fotos** (fixa no topo).
- Salva no álbum **Watermarked** da galeria/Fotos.

## Estrutura

```
flutter_app/
├── pubspec.yaml
└── lib/
    ├── main.dart            # app + tema
    ├── home_page.dart       # toda a UI e o fluxo
    ├── watermark_engine.dart# composição em Dart (roda em isolate via compute)
    └── models.dart
```

> As pastas `ios/` e `android/` **não** ficam no repositório — elas são geradas
> pelo CI com `flutter create` antes do build (veja
> `.github/workflows/flutter-build.yml`).

## Como buildar

### Pela nuvem (GitHub Actions) — recomendado
O workflow **Build Flutter (iOS + Android)** roda sozinho a cada push nesta
branch (ou manualmente em *Actions → Run workflow*). Ele:

1. instala o Flutter;
2. gera as pastas de plataforma (`flutter create`);
3. adiciona as permissões de Fotos no `Info.plist` do iOS;
4. builda e publica os artefatos:
   - **ios-unsigned-ipa** — `.ipa` **sem assinatura**;
   - **android-apk** — APK de debug.

> O `.ipa` sai **sem assinatura**. Para instalar num iPhone real é preciso
> **assinar** com um Apple ID (instalação pessoal) ou conta de desenvolvedor
> (TestFlight/App Store). Sem assinatura ele não instala — é uma limitação da
> Apple, não do app.

### Localmente (se você tiver um Mac)
```bash
cd flutter_app
flutter create --platforms=ios,android --org com.tekz --project-name photo_watermark .
flutter pub get
flutter run            # com um iPhone/simulador conectado
# ou: flutter build ipa
```
