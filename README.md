# JCV Watermarker (Windows)

Aplicativo para Windows que aplica **logos** e **textos** em qualquer quantidade
de fotos de uma só vez:

- uma fileira de logos na **base** (da esquerda para a direita ou centralizada);
- uma fileira de logos no **canto superior esquerdo**;
- uma única **logo principal** no **canto superior direito**;
- **textos** com fontes do computador, cores, contorno e arco-íris, sempre
  centralizados na horizontal.

O código fica em [`flutter_app/`](flutter_app/) (Flutter/Dart). O build é feito
pelo GitHub Actions (**Build Windows app**), que publica o ZIP na release
**Latest Windows build** (tag `windows-latest`).

## Como usar

1. Baixe `JCV-Watermarker-Windows.zip` da release, extraia e abra
   `JCV Watermarker.exe` — não precisa instalar.
2. **Adicione as fotos** e depois as logos/textos; a pré-visualização das
   primeiras 5 fotos atualiza ao vivo (clique para abrir em tela cheia; a roda do
   mouse dá zoom).
3. **Aplicar e salvar tudo** grava cada foto como JPEG de alta qualidade em
   `Imagens\JCV Watermarker\<data hora>`. Durante o salvamento só o botão
   **Cancelar** fica ativo; ao cancelar, o app volta exatamente ao estado
   anterior.
4. Ao fechar o app nada fica guardado — cada abertura começa um projeto novo.
