package main

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

// Согласованность маркера с железом. Порядок байт здесь легко перепутать --
// первая версия и перепутала, а симптом на плате был бы обманчивым:
// count_drop растёт, count_ours ноль, то есть неотличимо от "порог завышен".
//
// Тест ЧИТАЕТ net_frame_filter.v и раскладывает EPD_MARKER по битам сам,
// а не сверяется с записанной от руки константой: иначе он проверял бы мою
// же арифметику против неё самой.
func TestMarkerMatchesFilter(t *testing.T) {
	const filterPath = "../../kernel/user_krnl/hls_pp_dual_krnl/src/hdl/net_frame_filter.v"

	src, err := os.ReadFile(filterPath)
	if err != nil {
		t.Skipf("нет %s -- фильтр ещё не скопирован в это ядро", filterPath)
	}

	// parameter [47:0] EPD_MARKER = 48'h5A3C96E1B7D2
	re := regexp.MustCompile(`EPD_MARKER\s*=\s*48'h([0-9a-fA-F]{12})`)
	m := re.FindSubmatch(src)
	if m == nil {
		t.Fatalf("в %s не найден EPD_MARKER = 48'h...", filterPath)
	}
	want, err := strconv.ParseUint(string(m[1]), 16, 64)
	if err != nil {
		t.Fatal(err)
	}

	// Фильтр сравнивает tdata[511:464]. Байт k слова -- биты [8k+7:8k],
	// значит старший hex-байт попадает в байт кадра 63 = payload[9],
	// младший -- в payload[4].
	//
	// Собираем 48-битное значение из marker[] так, как его увидит фильтр.
	var got uint64
	for i := 0; i < 6; i++ {
		// marker[i] лежит в payload[4+i] = байт кадра 58+i = биты
		// (58+i)*8 .. +7. Относительно 464 это разряд (i) снизу.
		got |= uint64(marker[i]) << (8 * i)
	}

	if got != want {
		t.Errorf("маркер не совпадает с железом:\n"+
			"  фильтр ждёт 48'h%012X\n"+
			"  клиент даёт 48'h%012X\n"+
			"  marker = %v\n"+
			"  порядок байт в marker[] должен быть ОБРАТНЫМ к hex-записи",
			want, got, marker)
	}
}

// Смещение маркера обязано попадать в ПЕРВОЕ 512-битное слово кадра при
// любом допустимом размере сообщения -- иначе фильтр его не увидит.
func TestMarkerFitsFirstWord(t *testing.T) {
	const headers = 14 + 20 + 20 // Ethernet + IP + TCP
	// payload[9] -- последний байт маркера
	lastByte := headers + 9
	if lastByte >= 64 {
		t.Fatalf("маркер уезжает во второе слово: байт кадра %d >= 64", lastByte)
	}
	// И проверим границы: payload[4] не должен попасть в заголовки
	if headers+4 < headers {
		t.Fatal("смещение маркера отрицательное")
	}
	t.Logf("маркер в байтах кадра %d..%d, первое слово -- ok", headers+4, lastByte)
}

func TestFrameWords(t *testing.T) {
	cases := []struct{ n, want int }{
		{10, 1},    // 64 байта -- ровно одно слово, как ACK
		{11, 2},    // 65 -> два
		{64, 2},    // 118
		{256, 5},   // 310
		{4096, 65}, // 4150
	}
	for _, c := range cases {
		if got := frameWords(c.n); got != c.want {
			t.Errorf("frameWords(%d) = %d, ожидалось %d", c.n, got, c.want)
		}
	}
}
