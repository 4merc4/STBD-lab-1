using EcommerceApp;
using EcommerceApp.Models;
using Npgsql;

// Рядок підключення: змінна середовища ECOMMERCE_CONNSTR або значення за замовчуванням.
// Search Path=shop - усі об'єкти БД лежать у схемі "shop".
var connectionString = Environment.GetEnvironmentVariable("ECOMMERCE_CONNSTR")
    ?? "Host=localhost;Port=5432;Database=ecommerce;Username=postgres;Password=postgres;Search Path=shop,public";

await using var dataSource = NpgsqlDataSource.Create(connectionString);

static void Title(string text) => Console.WriteLine($"\n=== {text} ===");
static string Money(decimal v) => v.ToString("N2");

// ---------------------------------------------------------------------------
// Підготовка: довідкові дані (адмін, магазин)
// ---------------------------------------------------------------------------
long adminId;
StoreDto store;
ShippingMethodDto shipping;
IReadOnlyList<CatalogItemDto> catalog;

List<CatalogItemDto> offers;

await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync();
    var admin = await uow.Users.GetByEmailAsync("admin@shop.ua")
                ?? throw new InvalidOperationException("Спочатку виконайте scripts/install.sh (демо-дані).");
    adminId = admin.Id;
    store = await uow.Stores.GetBySlugAsync("techhub") ?? throw new InvalidOperationException("Магазин techhub не знайдено.");
    shipping = (await uow.Stores.GetShippingMethodsAsync(store.Id)).First();
    catalog = await uow.Products.GetCatalogAsync(store.Id);

    // Для демо беремо два найдешевші товари й поповнюємо склад (від імені адміна),
    // щоб сценарій можна було запускати повторно.
    offers = catalog.OrderBy(c => c.Price).Take(2).ToList();
    await uow.SetActorAsync(adminId);
    foreach (var offer in offers)
        await uow.Products.RestockAsync(offer.StoreProductId, 3);

    await uow.CommitAsync();
}

Title($"Каталог магазину {store.Name}");
foreach (var item in catalog)
    Console.WriteLine($"  [{item.StoreProductId}] {item.ProductName,-40} {Money(item.Price),10} {item.Currency}  залишок: {item.StockQty}");

// ---------------------------------------------------------------------------
// Сценарій 1. Одна транзакція, кілька сутностей:
//   користувач -> адреса -> кошик -> замовлення (+ промокод) -> оплата
// ---------------------------------------------------------------------------
long customerId, orderId;

await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync();

    var email = $"demo.{Guid.NewGuid():N}@example.com";
    customerId = await uow.Users.RegisterAsync(email, "demo-hash", "Демо", "Покупець", "+380000000000");
    await uow.SetActorAsync(customerId);                       // подальші зміни аудитуються на цього користувача

    var addressId = await uow.Users.AddAddressAsync(customerId, "Дім", "Україна", "Київ", "вул. Демонстраційна, 1", "01001", true);

    foreach (var offer in offers)
        await uow.Carts.AddItemAsync(customerId, offer.StoreProductId, 1);

    Title("Кошик");
    foreach (var line in await uow.Carts.GetLinesAsync(customerId, store.Id))
        Console.WriteLine($"  {line.ProductName,-40} {line.Quantity} x {Money(line.UnitPrice)} = {Money(line.LineTotal)}");

    orderId = await uow.Orders.PlaceAsync(customerId, store.Id, addressId, shipping.ShippingMethodId, "WELCOME10", "Створено з C#");
    var placed = await uow.Orders.GetSummaryAsync(orderId);
    await uow.Orders.PayAsync(orderId, "card", placed!.TotalAmount, "TX-" + Guid.NewGuid().ToString("N")[..12]);

    var order = await uow.Orders.GetSummaryAsync(orderId);
    Title("Замовлення (усе в одній транзакції)");
    Console.WriteLine($"  {order!.OrderNumber}: статус {order.Status}, товарів {Money(order.Subtotal)}, знижка {Money(order.DiscountAmount)}, " +
                      $"доставка {Money(order.ShippingCost)}, РАЗОМ {Money(order.TotalAmount)}, оплата: {order.PaymentStatus}");

    await uow.CommitAsync();
}

// ---------------------------------------------------------------------------
// Сценарій 2. Атомарність: помилка в середині -> відкат УСІХ змін транзакції
// ---------------------------------------------------------------------------
Title("Відкат транзакції при помилці");
var laptop = catalog.First(c => c.ProductName.Contains("Ноутбук"));
await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync(customerId);
    try
    {
        await uow.Carts.AddItemAsync(customerId, laptop.StoreProductId, 1);       // успішно...
        await uow.Carts.AddItemAsync(customerId, laptop.StoreProductId, 1000);    // ...а це перевищує залишок
        await uow.CommitAsync();
    }
    catch (PostgresException ex)
    {
        Console.WriteLine($"  Помилка БД: {ex.MessageText}");
        await uow.RollbackAsync();
        Console.WriteLine("  Транзакцію скасовано.");
    }
}
await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync();
    var lines = await uow.Carts.GetLinesAsync(customerId, store.Id);
    Console.WriteLine($"  Рядків у кошику після відкату: {lines.Count} (перше успішне додавання теж скасовано)");
    await uow.CommitAsync();
}

// ---------------------------------------------------------------------------
// Сценарій 3. Soft delete та відновлення товару (від імені адміністратора)
// ---------------------------------------------------------------------------
Title("Soft delete товару");
await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync(adminId);
    var target = offers[0];

    await uow.Products.SoftDeleteAsync(target.ProductId);
    var inCatalog = (await uow.Products.GetCatalogAsync(store.Id)).Any(c => c.ProductId == target.ProductId);
    Console.WriteLine($"  Після видалення '{target.ProductName}' у каталозі: {(inCatalog ? "є" : "немає")}");
    foreach (var d in await uow.Products.GetDeletedAsync())
        Console.WriteLine($"  Видалено: {d.Sku} '{d.ProductName}', {d.DeletedAt:u}, ким: {d.DeletedByName}");

    await uow.Products.RestoreAsync(target.ProductId);
    var restored = (await uow.Products.GetCatalogAsync(store.Id)).Any(c => c.ProductId == target.ProductId);
    Console.WriteLine($"  Після відновлення у каталозі: {(restored ? "є" : "немає")}");
    await uow.CommitAsync();
}

// ---------------------------------------------------------------------------
// Сценарій 4. Виконання замовлення персоналом і відгук покупця
// ---------------------------------------------------------------------------
Title("Відправка, доставка, відгук");
await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync(adminId);
    await uow.Orders.ShipAsync(orderId, "Нова Пошта", "59000999888777");
    await uow.Orders.MarkDeliveredAsync(orderId);

    await uow.SetActorAsync(customerId);
    await uow.Reviews.AddAsync(customerId, offers[0].ProductId, 5, "Все чудово", "Відгук створено з C#");

    foreach (var h in await uow.Orders.GetHistoryAsync(orderId))
        Console.WriteLine($"  {h.ChangedAt:HH:mm:ss}  {h.OldStatus ?? "-",-11} -> {h.NewStatus,-11} ({h.ChangedByName})");

    var reviews = await uow.Reviews.GetForProductAsync(offers[0].ProductId);
    Console.WriteLine($"  Відгуків на товар: {reviews.Count}");
    await uow.CommitAsync();
}

// ---------------------------------------------------------------------------
// Сценарій 5. Звіти з розрізів та повнотекстовий пошук
// ---------------------------------------------------------------------------
Title("Продажі по магазинах");
await using (var uow = new UnitOfWork(dataSource))
{
    await uow.BeginAsync();
    foreach (var s in await uow.Stores.GetSalesSummaryAsync())
        Console.WriteLine($"  {s.StoreName,-10} замовлень: {s.OrdersCount,3}  виручка: {Money(s.Revenue),12}  середній чек: {Money(s.AvgOrderValue)}");

    Title("Пошук 'смартфон samsung' у TechHub");
    foreach (var hit in await uow.Products.SearchAsync(store.Id, "смартфон samsung"))
        Console.WriteLine($"  {hit.ProductName} - {Money(hit.Price)} (rank {hit.Rank:F3})");

    Title("Низький залишок");
    foreach (var low in await uow.Products.GetLowStockAsync())
        Console.WriteLine($"  {low.StoreName,-10} {low.ProductName,-40} залишок {low.StockQty}");
    await uow.CommitAsync();
}
