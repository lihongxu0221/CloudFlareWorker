/**
 * Cloudflare Workers 运行时内置模块类型声明（仅用于本地编辑器，不参与部署打包）。
 * @see https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/
 */
declare module "cloudflare:sockets" {
  export interface SocketAddress {
    hostname: string;
    port: number;
  }

  export interface SocketOptions {
    secureTransport?: "on" | "off" | "starttls";
    allowHalfOpen?: boolean;
  }

  export interface Socket {
    readonly readable: ReadableStream<Uint8Array>;
    readonly writable: WritableStream<Uint8Array>;
    readonly opened: Promise<SocketInfo>;
    readonly closed: Promise<void>;
    close(): Promise<void>;
    startTls(): Socket;
  }

  export interface SocketInfo {
    remoteAddress?: string;
    localAddress?: string;
  }

  export function connect(
    address: string | SocketAddress,
    options?: SocketOptions
  ): Socket;
}
