---- MODULE PaymentLifecycle ----
EXTENDS Naturals

ValidRefund(captured, refunded, amount) == refunded + amount <= captured
ValidReversal(hasCapture, reversalCount) == hasCapture /\ reversalCount = 0

====
