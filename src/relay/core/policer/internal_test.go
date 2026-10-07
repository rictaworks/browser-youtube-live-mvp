package policer

// テストからだけ使う、内部の状態の確認口（保持している項目の数と、確保している領域）。本体には持たせない。

func (p *IngressPolicer) liveEntries() int { return len(p.entries) - p.head }

func (p *IngressPolicer) capacity() int { return cap(p.entries) }
