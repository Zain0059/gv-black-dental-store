(function(){
  const config=window.SUPABASE_CONFIG||{};
  const client=window.supabase&&config.url&&config.publishableKey?window.supabase.createClient(config.url,config.publishableKey):null;
  function requireClient(){if(!client)throw new Error('إعداد Supabase أو مكتبة الاتصال غير متاح.');return client}
  function unwrap(result){if(result.error)throw result.error;return result.data}
  async function loadStore(){
    const sb=requireClient(),session=unwrap(await sb.auth.getSession()).session;
    if(!session?.user)throw new Error('سجّل الدخول أولًا.');
    const profile=unwrap(await sb.from('profiles').select('id,role,active').eq('id',session.user.id).maybeSingle());
    if(!profile||!profile.active)throw new Error('لا يوجد ملف موظف نشط لهذا الحساب. اطلب من مالك المتجر تفعيل الحساب.');
    const [productResult,customerResult,invoiceResult]=await Promise.all([
      sb.from('products').select('id,sku,name,manufacturer,gtin,unit_price,stock_qty,active').eq('active',true).order('name'),
      sb.from('customers').select('id,name,phone,email,address,opening_balance,active').eq('active',true).order('name'),
      sb.from('invoices').select('id,invoice_no,customer_id,status,total,created_at,customer:customers(name),invoice_items(quantity,unit_price,sku_snapshot,name_snapshot),payments(amount,method,received_at)').eq('status','issued').order('created_at',{ascending:false})
    ]);
    const productRows=unwrap(productResult)||[],customerRows=unwrap(customerResult)||[],invoiceRows=unwrap(invoiceResult)||[],dueByCustomer=new Map();
    const mappedInvoices=invoiceRows.map(row=>{const paid=(row.payments||[]).reduce((sum,p)=>sum+Number(p.amount||0),0),customer=row.customer?.name||'عميل غير معروف';dueByCustomer.set(row.customer_id,(dueByCustomer.get(row.customer_id)||0)+Math.max(0,Number(row.total)-paid));return{id:row.id,no:row.invoice_no,customer,date:String(row.created_at).slice(0,10),total:Number(row.total),paid,items:(row.invoice_items||[]).map(i=>({code:i.sku_snapshot,name:i.name_snapshot,quantity:Number(i.quantity),unitPrice:Number(i.unit_price)}))}});
    const methods={cash:'نقدي',bank_transfer:'تحويل بنكي',card:'بطاقة',wallet:'محفظة إلكترونية'};
    const payments=invoiceRows.flatMap(row=>(row.payments||[]).map(p=>({date:String(p.received_at).slice(0,10),customer:row.customer?.name||'عميل غير معروف',invoice:row.invoice_no,amount:Number(p.amount),method:methods[p.method]||p.method})));
    return{products:productRows.map(p=>({id:p.id,code:p.sku,name:p.name,company:p.manufacturer||'',price:Number(p.unit_price),stock:Number(p.stock_qty),gtin:p.gtin||''})),customers:customerRows.map(c=>({id:c.id,name:c.name,phone:c.phone||'',email:c.email||'',address:c.address||'',balance:Number(c.opening_balance||0)+(dueByCustomer.get(c.id)||0)})),invoices:mappedInvoices,payments};
  }
  async function createProduct(p){return unwrap(await requireClient().from('products').insert({sku:p.sku,name:p.name,manufacturer:p.manufacturer||'',unit_price:p.unitPrice,gtin:null,active:true}).select('id,sku,name').single())}
  async function adjustStock(id,delta,reason){return unwrap(await requireClient().rpc('adjust_stock',{p_product_id:id,p_delta:delta,p_reason:reason}))}
  async function archiveProduct(id){return unwrap(await requireClient().from('products').update({active:false}).eq('id',id).select('id').single())}
  async function setProductGTIN(id,gtin,conflictId){const sb=requireClient();if(conflictId)unwrap(await sb.from('products').update({gtin:null}).eq('id',conflictId).select('id').single());return unwrap(await sb.from('products').update({gtin:gtin||null}).eq('id',id).select('id').single())}
  async function createCustomer(c){return unwrap(await requireClient().from('customers').insert({name:c.name,phone:c.phone||'',email:c.email||'',address:c.address||'',opening_balance:c.openingBalance||0,active:true}).select('id,name,phone,opening_balance').single())}
  async function createSale(s){return unwrap(await requireClient().rpc('create_sale',{p_customer_id:s.customerId,p_items:[{product_id:s.productId,quantity:s.quantity}],p_paid:s.paid,p_method:s.method||'cash'}))}
  async function recordPayment(p){return unwrap(await requireClient().rpc('record_payment',{p_invoice_id:p.invoiceId,p_amount:p.amount,p_method:p.method||'cash'}))}
  async function signIn(email,password){return unwrap(await requireClient().auth.signInWithPassword({email,password})).user}
  async function signOut(){return unwrap(await requireClient().auth.signOut())}
  async function getSession(){return unwrap(await requireClient().auth.getSession()).session}
  window.GVCloud={loadStore,createProduct,adjustStock,archiveProduct,setProductGTIN,createCustomer,createSale,recordPayment,signIn,signOut,getSession};
})();