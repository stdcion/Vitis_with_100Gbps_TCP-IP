/**********
Простой TCP echo-сервер для проверки методики измерения задержки
на localhost, до запуска на FPGA.

Ведёт себя так же, как hls_pingpong_krnl: принимает байты и
немедленно отправляет их обратно, ничего не интерпретируя.
Это позволяет заранее проверить, что выбранный измеритель
(netperf -N, pingpong_client) вообще работает с plain echo.

ВНИМАНИЕ: цифры, полученные на localhost, показывают только
накладные расходы измерителя и петлевого интерфейса. Они НЕ
предсказывают задержку FPGA — там будет реальная сеть и стек.
Смысл этого прогона — отладить методику, а не получить результат.

Сборка и запуск:
    javac EchoServer.java
    java EchoServer 5001

Затем в другом терминале:
    netperf -N -H 127.0.0.1 -p 5001 -t omni -l 10 -- -r 64,64 \
        -o MIN_LATENCY,P50_LATENCY,P99_LATENCY,MAX_LATENCY,MEAN_LATENCY

или:
    ./pingpong_client 127.0.0.1 5001 64 10000 1000
**********/
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

public class EchoServer {

    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 5001;

        ServerSocket server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(port));

        System.out.println("echo server listening on port " + port);
        System.out.println("press Ctrl+C to stop");

        // По одному клиенту за раз — как в FPGA-ядре.
        // После отключения клиента ждём следующего.
        while (true) {
            Socket client = server.accept();

            // Критично для замера задержки: без этого алгоритм Нейгла
            // будет копить мелкие ответы и добавит миллисекунды.
            client.setTcpNoDelay(true);

            System.out.println("client connected: " + client.getRemoteSocketAddress());

            long messages = 0;
            long bytes = 0;
            try {
                InputStream in = client.getInputStream();
                OutputStream out = client.getOutputStream();
                byte[] buf = new byte[65536];

                while (true) {
                    int n = in.read(buf);
                    if (n < 0) break;          // клиент закрыл соединение

                    out.write(buf, 0, n);
                    out.flush();

                    messages++;
                    bytes += n;
                }
            } catch (Exception e) {
                System.out.println("client error: " + e.getMessage());
            } finally {
                try { client.close(); } catch (Exception ignored) {}
                System.out.println("client disconnected after "
                        + messages + " reads, " + bytes + " bytes");
            }
        }
    }
}
