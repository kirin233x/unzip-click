// 极简 zstd 解压器：只实现 `zstd -d -qq`（stdin -> stdout）。
// 老版本 macOS 的 bsdtar 不内置 zstd，会去 PATH 里找外部 zstd 程序；
// UnzipClick 把本程序放进 App 里并加入 PATH，用户无需安装 zstd。
#include <stdio.h>
#include <stdlib.h>
#include "zstd.h"

int main(void) {
    size_t inSize = ZSTD_DStreamInSize(), outSize = ZSTD_DStreamOutSize();
    void *inBuf = malloc(inSize), *outBuf = malloc(outSize);
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    if (!inBuf || !outBuf || !ctx) return 1;

    size_t n, lastRet = 0;
    while ((n = fread(inBuf, 1, inSize, stdin)) > 0) {
        ZSTD_inBuffer in = {inBuf, n, 0};
        while (in.pos < in.size) {
            ZSTD_outBuffer out = {outBuf, outSize, 0};
            lastRet = ZSTD_decompressStream(ctx, &out, &in);
            if (ZSTD_isError(lastRet)) {
                fprintf(stderr, "zstd: %s\n", ZSTD_getErrorName(lastRet));
                return 1;
            }
            if (fwrite(outBuf, 1, out.pos, stdout) != out.pos) return 1;
        }
    }
    if (lastRet != 0) {
        fprintf(stderr, "zstd: unexpected end of input\n");
        return 1;
    }
    return fflush(stdout) == 0 ? 0 : 1;
}
