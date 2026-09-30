export const startFdListener: (socketPath: string) => boolean;
export const pollFd: () => number;
export const stopFdListener: () => boolean;
export const sendFd: (socketPath: string, fd: number, timeoutMs: number) => boolean;
